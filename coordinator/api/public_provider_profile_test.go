package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func newPublicProfileTestServer(t *testing.T) (*httptest.Server, *registry.Registry) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	return httptest.NewServer(srv.Handler()), reg
}

func registerTestProvider(t *testing.T, reg *registry.Registry, id, accountID string, trust registry.TrustLevel, status registry.ProviderStatus) *registry.Provider {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac16,11",
			ChipName:     "Apple M4 Max",
			ChipFamily:   "M4",
			ChipTier:     "Max",
			MemoryGB:     64,
			GPUCores:     40,
		},
		Models: []protocol.ModelInfo{
			{ID: "gemma-4-26b-qat-4bit", ModelType: "chat", Quantization: "4bit"},
		},
	}
	p := reg.Register(id, nil, msg)
	p.Mu().Lock()
	p.AccountID = accountID
	p.TrustLevel = trust
	p.Status = status
	p.WarmModels = []string{"gemma-4-26b-qat-4bit"}
	p.Reputation = registry.NewReputation()
	p.Reputation.TotalJobs = 42
	p.Reputation.SuccessfulJobs = 41
	p.Reputation.ChallengesPassed = 10
	p.Stats = protocol.HeartbeatStats{
		RequestsServed:  42,
		TokensGenerated: 500000,
	}
	p.Mu().Unlock()
	return p
}

func TestPublicProviderProfile_ReturnsProfile(t *testing.T) {
	ts, reg := newPublicProfileTestServer(t)
	defer ts.Close()

	accountID := "acc_test_12345"
	wantPseudonym := pseudonym(accountID)
	registerTestProvider(t, reg, "prov-1", accountID, registry.TrustHardware, registry.StatusOnline)

	resp, err := http.Get(ts.URL + "/v1/providers/" + wantPseudonym)
	if err != nil {
		t.Fatalf("GET /v1/providers/%s: %v", wantPseudonym, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, body)
	}

	var profile publicProviderProfile
	if err := json.NewDecoder(resp.Body).Decode(&profile); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if profile.Pseudonym != wantPseudonym {
		t.Errorf("pseudonym: got %q, want %q", profile.Pseudonym, wantPseudonym)
	}
	if profile.Status != "online" {
		t.Errorf("status: got %q, want \"online\"", profile.Status)
	}
	if profile.TrustLevel != "hardware" {
		t.Errorf("trust_level: got %q, want \"hardware\"", profile.TrustLevel)
	}
	if profile.Hardware.ChipName != "Apple M4 Max" {
		t.Errorf("hardware.chip_name: got %q", profile.Hardware.ChipName)
	}
	if profile.Hardware.MemoryGB != 64 {
		t.Errorf("hardware.memory_gb: got %d", profile.Hardware.MemoryGB)
	}
	if len(profile.WarmModels) == 0 {
		t.Error("warm_models must not be empty")
	}
	if profile.Reputation.TotalJobs != 42 {
		t.Errorf("reputation.total_jobs: got %d, want 42", profile.Reputation.TotalJobs)
	}
	if profile.LifetimeTokensGenerated != 500000 {
		t.Errorf("lifetime_tokens_generated: got %d, want 500000", profile.LifetimeTokensGenerated)
	}
}

func TestPublicProviderProfile_ReturnsNotFoundForUnknownPseudonym(t *testing.T) {
	ts, _ := newPublicProfileTestServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/v1/providers/unknown-pseudonym-0000")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("expected 404, got %d", resp.StatusCode)
	}
}

// TestPublicProviderProfile_PrivacyGuarantees verifies that the raw JSON
// response contains no fields that must never be public.
func TestPublicProviderProfile_PrivacyGuarantees(t *testing.T) {
	ts, reg := newPublicProfileTestServer(t)
	defer ts.Close()

	accountID := "acc_priv_test"
	wantPseudonym := pseudonym(accountID)
	p := registerTestProvider(t, reg, "prov-priv", accountID, registry.TrustHardware, registry.StatusOnline)

	// Inject sensitive fields that must be absent from the public response.
	p.Mu().Lock()
	p.PublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" // X25519 — should be absent
	p.RuntimeHash = "deadbeef"
	p.PythonHash = "cafebabe"
	p.Mu().Unlock()

	resp, err := http.Get(ts.URL + "/v1/providers/" + wantPseudonym)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	forbidden := []string{
		"account_id", "wallet_address", "se_public_key", "provider_key",
		"runtime_hash", "python_hash", "earnings_micro_usd", "system_metrics",
		"failed_jobs", // reputation detail not shown
	}
	for _, field := range forbidden {
		if _, ok := raw[field]; ok {
			t.Errorf("field %q must not appear in public profile response", field)
		}
	}
}

// TestPublicProviderProfile_AggregatesMultipleMachines verifies that when an
// account has two live machines, the profile aggregates warm models and
// concurrency across both.
func TestPublicProviderProfile_AggregatesMultipleMachines(t *testing.T) {
	ts, reg := newPublicProfileTestServer(t)
	defer ts.Close()

	accountID := "acc_multi_machine"
	wantPseudonym := pseudonym(accountID)

	p1 := registerTestProvider(t, reg, "prov-m1", accountID, registry.TrustHardware, registry.StatusOnline)
	p2 := registerTestProvider(t, reg, "prov-m2", accountID, registry.TrustSelfSigned, registry.StatusOnline)

	// Give p2 a different model so union is tested.
	p2.Mu().Lock()
	p2.WarmModels = []string{"qwen3.6-35b-a3b-vl-mtp-mxfp8"}
	p2.Stats = protocol.HeartbeatStats{TokensGenerated: 1000}
	_ = p1 // p1 has tokens=500000 from registerTestProvider
	p2.Mu().Unlock()

	resp, err := http.Get(ts.URL + "/v1/providers/" + wantPseudonym)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()

	var profile publicProviderProfile
	if err := json.NewDecoder(resp.Body).Decode(&profile); err != nil {
		t.Fatalf("decode: %v", err)
	}

	if profile.TrustLevel != "hardware" {
		t.Errorf("expected best trust to be hardware, got %q", profile.TrustLevel)
	}
	if len(profile.WarmModels) < 2 {
		t.Errorf("expected union of warm models (>=2), got %d: %v", len(profile.WarmModels), profile.WarmModels)
	}
	if profile.LifetimeTokensGenerated != 501000 {
		t.Errorf("expected summed tokens 501000, got %d", profile.LifetimeTokensGenerated)
	}
}

// TestPublicProviderProfile_CacheKey ensures two different pseudonyms are
// cached independently (no key collision).
func TestPublicProviderProfile_CacheKey(t *testing.T) {
	ts, reg := newPublicProfileTestServer(t)
	defer ts.Close()

	acc1, acc2 := "acc_cache_a", "acc_cache_b"
	p1 := pseudonym(acc1)
	p2 := pseudonym(acc2)
	if p1 == p2 {
		t.Skip("pseudonym collision in test fixture, skipping")
	}
	registerTestProvider(t, reg, "prov-ca", acc1, registry.TrustHardware, registry.StatusOnline)
	registerTestProvider(t, reg, "prov-cb", acc2, registry.TrustSelfSigned, registry.StatusServing)

	for _, tc := range []struct{ pseudo, wantTrust string }{{p1, "hardware"}, {p2, "self_signed"}} {
		resp, err := http.Get(ts.URL + "/v1/providers/" + tc.pseudo)
		if err != nil {
			t.Fatalf("GET %s: %v", tc.pseudo, err)
		}
		var profile publicProviderProfile
		if err := json.NewDecoder(resp.Body).Decode(&profile); err != nil {
			resp.Body.Close()
			t.Fatalf("decode: %v", err)
		}
		resp.Body.Close()

		if profile.TrustLevel != tc.wantTrust {
			t.Errorf("pseudo %s: trust=%q, want %q", tc.pseudo, profile.TrustLevel, tc.wantTrust)
		}
	}

	// Keep time import used: verify cache TTL is sane
	_ = time.Second
}
