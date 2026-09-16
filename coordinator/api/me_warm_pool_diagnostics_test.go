package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// registerWarmPoolTestProvider connects a healthy, idle provider that advertises
// `model` while holding a different model in its only slot — i.e. cold for
// `model` — with the reported free-for-load memory set to freeForLoadGB.
func registerWarmPoolTestProvider(t *testing.T, srv *Server, id, accountID, model string, totalMemoryGB, freeForLoadGB float64) {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Models:   []protocol.ModelInfo{{ID: model, ModelType: "chat"}},
		Hardware: protocol.Hardware{MemoryGB: int(totalMemoryGB)},
		Backend:  registry.BackendMLXSwift,
	}
	p := srv.registry.Register(id, nil, msg)
	free := freeForLoadGB
	p.Mu().Lock()
	p.AccountID = accountID
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	// The private-text chokepoint the public routing gate applies. Without
	// these the machine is fenced by trust_or_runtime long before any memory
	// gate is reached, and the test would assert nothing about warm-pool
	// eligibility.
	p.PublicKey = "test-x25519-key"
	p.EncryptedResponseChunks = true
	p.PrivacyCapabilities = &protocol.PrivacyCapabilities{
		TextBackendInprocess: true,
		TextProxyDisabled:    true,
		AntiDebugEnabled:     true,
		CoreDumpsDisabled:    true,
		EnvScrubbed:          true,
	}
	p.SystemMetrics = protocol.SystemMetrics{ThermalState: "nominal"}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: totalMemoryGB,
		FreeForLoadGB: &free,
		Slots: []protocol.BackendSlotCapacity{
			{Model: "unrelated-model", State: "idle"},
		},
	}
	p.Mu().Unlock()
}

// wireWarmPool is a decode-side mirror of the JSON the console UI keys off. It
// is deliberately a separate struct from the Go type so a field rename in the
// registry breaks this test rather than silently breaking the dashboard.
type wireWarmPool struct {
	TotalMemoryGB float64  `json:"total_memory_gb"`
	FreeForLoadGB *float64 `json:"free_for_load_gb"`
	Models        []struct {
		ID                 string  `json:"id"`
		Warm               bool    `json:"warm"`
		Eligible           bool    `json:"eligible"`
		Blocker            string  `json:"blocker"`
		BlockerDescription string  `json:"blocker_description"`
		Permanent          bool    `json:"permanent"`
		RequiredMemoryGB   float64 `json:"required_memory_gb"`
		WeightsGB          float64 `json:"weights_gb"`
		LoadThresholdGiB   float64 `json:"load_threshold_gib"`
	} `json:"models"`
	EligibleModels           int `json:"eligible_models"`
	WarmModels               int `json:"warm_models"`
	PermanentlyBlockedModels int `json:"permanently_blocked_models"`
	ChallengeMaxAgeSeconds   int `json:"challenge_max_age_seconds"`
}

type wireMyProviders struct {
	Providers []struct {
		ID       string        `json:"id"`
		Online   bool          `json:"online"`
		WarmPool *wireWarmPool `json:"warm_pool"`
	} `json:"providers"`
}

func fetchMyProviders(t *testing.T, srv *Server, accountID string) wireMyProviders {
	t.Helper()
	r := reqWithUser(http.MethodGet, "/v1/me/providers", "", accountID)
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp wireMyProviders
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v\nbody: %s", err, w.Body.String())
	}
	return resp
}

// A machine permanently too small for a model must say so on the wire, with the
// operator-facing description and the threshold attached — the shape the
// dashboard renders.
func TestMyProvidersExposesPermanentWarmPoolBlocker(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	model := "wire-too-large"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, MinRAMGB: 96, SizeGB: 40}})
	registerWarmPoolTestProvider(t, srv, "p-small", "acct-1", model, 32, 24)

	resp := fetchMyProviders(t, srv, "acct-1")
	if len(resp.Providers) != 1 {
		t.Fatalf("expected 1 provider card, got %d", len(resp.Providers))
	}
	wp := resp.Providers[0].WarmPool
	if wp == nil {
		t.Fatalf("warm_pool absent from an online machine's card")
	}
	if len(wp.Models) != 1 {
		t.Fatalf("expected 1 model row, got %d", len(wp.Models))
	}
	row := wp.Models[0]
	if row.Eligible {
		t.Fatalf("a 32 GB box must not be eligible for a 96 GB model")
	}
	if row.Blocker != "model_too_large" {
		t.Fatalf("blocker = %q, want model_too_large", row.Blocker)
	}
	if !row.Permanent {
		t.Fatalf("model_too_large must serialize as permanent")
	}
	if row.BlockerDescription == "" {
		t.Fatalf("blocker_description must be populated so a client need not carry its own copy")
	}
	if row.RequiredMemoryGB != 96 {
		t.Fatalf("required_memory_gb = %v, want 96", row.RequiredMemoryGB)
	}
	if wp.PermanentlyBlockedModels != 1 {
		t.Fatalf("permanently_blocked_models = %d, want 1", wp.PermanentlyBlockedModels)
	}
	if wp.ChallengeMaxAgeSeconds <= 0 {
		t.Fatalf("challenge_max_age_seconds must be populated, got %d", wp.ChallengeMaxAgeSeconds)
	}
}

// The transient memory verdict must NOT serialize as permanent: an operator
// must not be told to change hardware over a condition that clears on the next
// heartbeat.
func TestMyProvidersTransientBlockerIsNotPermanentOnTheWire(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	model := "wire-no-free"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	registerWarmPoolTestProvider(t, srv, "p-busy", "acct-1", model, 64, 1)

	wp := fetchMyProviders(t, srv, "acct-1").Providers[0].WarmPool
	if wp == nil {
		t.Fatalf("warm_pool absent")
	}
	row := wp.Models[0]
	if row.Blocker != "no_free_for_load" {
		t.Fatalf("blocker = %q, want no_free_for_load", row.Blocker)
	}
	if row.Permanent {
		t.Fatalf("no_free_for_load must not serialize as permanent")
	}
	if wp.FreeForLoadGB == nil || *wp.FreeForLoadGB != 1 {
		t.Fatalf("free_for_load_gb must be echoed so the operator sees the input; got %v", wp.FreeForLoadGB)
	}
}

// An eligible machine must report no blocker, so "waiting its turn" is visibly
// different from "excluded".
func TestMyProvidersEligibleMachineReportsNoBlocker(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	model := "wire-eligible"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	registerWarmPoolTestProvider(t, srv, "p-ready", "acct-1", model, 64, 48)

	wp := fetchMyProviders(t, srv, "acct-1").Providers[0].WarmPool
	if wp == nil {
		t.Fatalf("warm_pool absent")
	}
	row := wp.Models[0]
	if !row.Eligible {
		t.Fatalf("expected eligible, got blocker %q (%s)", row.Blocker, row.BlockerDescription)
	}
	if row.Blocker != "" {
		t.Fatalf("an eligible row must omit blocker, got %q", row.Blocker)
	}
	if wp.EligibleModels != 1 {
		t.Fatalf("eligible_models = %d, want 1", wp.EligibleModels)
	}
}

// An offline machine must carry no verdict at all: every input is live state,
// and a stale verdict is worse than none.
func TestMyProvidersOmitsWarmPoolForOfflineMachine(t *testing.T) {
	srv, st := newKeyTestServer(t)
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID:        "p-offline",
		AccountID: "acct-1",
		LastSeen:  time.Now().Add(-time.Hour),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	resp := fetchMyProviders(t, srv, "acct-1")
	if len(resp.Providers) != 1 {
		t.Fatalf("expected 1 card, got %d", len(resp.Providers))
	}
	if resp.Providers[0].Online {
		t.Fatalf("seeded machine should be offline")
	}
	if resp.Providers[0].WarmPool != nil {
		t.Fatalf("warm_pool must be omitted for an offline machine, got %+v", resp.Providers[0].WarmPool)
	}
}

// Another account's machine must not appear, so the new field cannot leak one
// operator's fleet shape to another.
func TestMyProvidersWarmPoolIsAccountScoped(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	model := "wire-scope"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	registerWarmPoolTestProvider(t, srv, "p-theirs", "acct-2", model, 64, 48)

	resp := fetchMyProviders(t, srv, "acct-1")
	for _, p := range resp.Providers {
		if p.ID == "p-theirs" {
			t.Fatalf("another account's machine leaked into /v1/me/providers")
		}
	}
}

// --- Review follow-ups -------------------------------------------------------

// A CONNECTED but UNTRUSTED machine must still receive a verdict. buildMyProvider
// clears Online for StatusUntrusted as well as StatusOffline, so gating the
// attach on Online withheld the diagnostic from exactly the machine that most
// needs it: the offline_untrusted_private blocker could never be explained
// through /v1/me/providers, contradicting the field's connected-machine contract.
func TestMyProvidersIncludesWarmPoolForConnectedUntrustedMachine(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	model := "wire-untrusted"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	registerWarmPoolTestProvider(t, srv, "p-untrusted", "acct-1", model, 64, 48)

	// Downgrade to untrusted while remaining CONNECTED (still in the registry).
	p := srv.registry.GetProvider("p-untrusted")
	if p == nil {
		t.Fatal("provider not in registry")
	}
	p.Mu().Lock()
	p.Status = registry.StatusUntrusted
	p.Mu().Unlock()

	resp := fetchMyProviders(t, srv, "acct-1")
	var card *struct {
		ID       string        `json:"id"`
		Online   bool          `json:"online"`
		WarmPool *wireWarmPool `json:"warm_pool"`
	}
	for i := range resp.Providers {
		if resp.Providers[i].ID == "p-untrusted" {
			card = &resp.Providers[i]
		}
	}
	if card == nil {
		t.Fatalf("machine missing from /v1/me/providers")
	}
	// Precondition: this is the shape the review describes — NOT online, but live.
	if card.Online {
		t.Fatalf("test shape wrong: an untrusted machine must report online=false")
	}
	if card.WarmPool == nil {
		t.Fatalf("warm_pool omitted for a CONNECTED untrusted machine: the untrusted case cannot be explained")
	}
	if len(card.WarmPool.Models) == 0 {
		t.Fatalf("warm_pool present but carries no model rows")
	}
	// And the verdict must name the reason rather than reading as eligible.
	row := card.WarmPool.Models[0]
	if row.Eligible {
		t.Fatalf("an untrusted machine must not be reported as an eligible warm target")
	}
	if row.Blocker != "offline_untrusted_private" {
		t.Fatalf("blocker = %q, want offline_untrusted_private", row.Blocker)
	}
	if row.BlockerDescription == "" {
		t.Fatalf("blocker_description must be populated so a client need not carry the mapping")
	}
}

// The padded load threshold must reach the wire, since the raw weights figure
// alone contradicts the verdict near the memory boundary.
func TestMyProvidersSerializesPaddedLoadThreshold(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	model := "wire-boundary"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	// 30 GB weights, 32 GiB reported free: raw size LOOKS like it fits, padded does not.
	registerWarmPoolTestProvider(t, srv, "p-boundary", "acct-1", model, 64, 32)

	resp := fetchMyProviders(t, srv, "acct-1")
	if len(resp.Providers) == 0 || resp.Providers[0].WarmPool == nil {
		t.Fatalf("no warm_pool on the card")
	}
	wp := resp.Providers[0].WarmPool
	if len(wp.Models) != 1 {
		t.Fatalf("expected 1 model row, got %d", len(wp.Models))
	}
	row := wp.Models[0]
	if row.Blocker != "no_free_for_load" {
		t.Fatalf("blocker = %q, want no_free_for_load", row.Blocker)
	}
	if row.LoadThresholdGiB == 0 {
		t.Fatalf("load_threshold_gib missing from the wire JSON")
	}
	if wp.FreeForLoadGB == nil {
		t.Fatalf("free_for_load_gb missing")
	}
	// The whole point: the serialized numbers must now EXPLAIN the verdict.
	if row.LoadThresholdGiB <= *wp.FreeForLoadGB {
		t.Fatalf("load_threshold_gib %v must exceed free_for_load_gb %v to explain the refusal",
			row.LoadThresholdGiB, *wp.FreeForLoadGB)
	}
	if !(row.WeightsGB < *wp.FreeForLoadGB) {
		t.Fatalf("test shape wrong: raw weights %v should look like it fits %v",
			row.WeightsGB, *wp.FreeForLoadGB)
	}
}
