package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

// testMeServer creates a Server with an in-memory store, registry, and a
// fake Privy user pre-seeded so handlers can resolve an account ID.
func testMeServer(t *testing.T) (*Server, *store.MemoryStore, *registry.Registry, *store.User) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("admin-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	user := &store.User{
		AccountID:           "acct-alice",
		PrivyUserID:         "did:privy:alice",
		Email:               "alice@example.com",
		SolanaWalletAddress: "AliceWalletAddress11111111111111111111111111",
	}
	if err := st.CreateUser(user); err != nil {
		t.Fatalf("create user: %v", err)
	}
	return srv, st, reg, user
}

// authedReq returns a GET request with the given user in context, simulating
// what requireAuth installs after Privy verification succeeds.
func authedReq(method, target string, user *store.User) *http.Request {
	r := httptest.NewRequest(method, target, nil)
	ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
	return r.WithContext(ctx)
}

func TestMyProviders_RequiresPrivyAuth(t *testing.T) {
	srv, _, _, _ := testMeServer(t)

	// API-key-only auth (no Privy user in context) — should be rejected.
	r := httptest.NewRequest(http.MethodGet, "/v1/me/providers", nil)
	r = r.WithContext(context.WithValue(r.Context(), ctxKeyConsumer, "api-key-only"))
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, r)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401: %s", w.Code, w.Body.String())
	}
}

func TestMyProviders_EmptyFleet(t *testing.T) {
	srv, _, _, user := testMeServer(t)

	r := authedReq(http.MethodGet, "/v1/me/providers", user)
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp myProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Providers) != 0 {
		t.Fatalf("len = %d, want 0", len(resp.Providers))
	}
	if resp.LatestProviderVersion == "" {
		t.Fatal("latest_provider_version should be populated")
	}
	if resp.HeartbeatTimeoutSec == 0 {
		t.Fatal("heartbeat_timeout_seconds should be populated")
	}
}

func TestMyProviders_PersistedOfflineMachineAppears(t *testing.T) {
	srv, st, _, user := testMeServer(t)

	hwJSON, _ := json.Marshal(protocol.Hardware{
		MachineModel: "Mac15,8",
		ChipName:     "Apple M3 Max",
		MemoryGB:     64,
		GPUCores:     40,
	})
	modelsJSON, _ := json.Marshal([]protocol.ModelInfo{
		{ID: "mlx-community/Qwen3.5-9B-MLX-4bit", ModelType: "text"},
	})
	rec := store.ProviderRecord{
		ID:                      "alice-machine-1",
		AccountID:               user.AccountID,
		Hardware:                hwJSON,
		Models:                  modelsJSON,
		Backend:                 "vllm-mlx",
		TrustLevel:              "hardware",
		Attested:                true,
		MDAVerified:             true,
		ACMEVerified:            true,
		Version:                 "0.3.10",
		RuntimeVerified:         true,
		SerialNumber:            "C02XYZ1234",
		LifetimeRequestsServed:  5_000,
		LifetimeTokensGenerated: 1_000_000,
		RegisteredAt:            time.Now().Add(-24 * time.Hour),
		LastSeen:                time.Now().Add(-30 * time.Minute),
	}
	if err := st.UpsertProvider(context.Background(), rec); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	r := authedReq(http.MethodGet, "/v1/me/providers", user)
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp myProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Providers) != 1 {
		t.Fatalf("len = %d, want 1", len(resp.Providers))
	}
	got := resp.Providers[0]
	if got.ID != "alice-machine-1" {
		t.Fatalf("id = %q, want alice-machine-1", got.ID)
	}
	if got.Status != "offline" {
		t.Fatalf("status = %q, want offline", got.Status)
	}
	if got.Online {
		t.Fatal("online should be false for an offline machine")
	}
	if got.Hardware.ChipName != "Apple M3 Max" {
		t.Fatalf("hardware.chip_name = %q, want Apple M3 Max", got.Hardware.ChipName)
	}
	if got.LifetimeRequestsServed != 5_000 {
		t.Fatalf("lifetime requests = %d, want 5000", got.LifetimeRequestsServed)
	}
	if !got.MDAVerified {
		t.Fatal("mda_verified should be true from persisted record")
	}
	if got.SystemMetrics != nil {
		t.Fatal("system_metrics should be nil for offline machine (no live snapshot)")
	}
}

func TestMyProviders_AccountIsolation(t *testing.T) {
	srv, st, _, alice := testMeServer(t)

	bob := &store.User{
		AccountID:   "acct-bob",
		PrivyUserID: "did:privy:bob",
		Email:       "bob@example.com",
	}
	if err := st.CreateUser(bob); err != nil {
		t.Fatalf("create bob: %v", err)
	}

	for _, rec := range []store.ProviderRecord{
		{ID: "alice-1", AccountID: alice.AccountID, LastSeen: time.Now()},
		{ID: "alice-2", AccountID: alice.AccountID, LastSeen: time.Now().Add(-time.Hour)},
		{ID: "bob-1", AccountID: bob.AccountID, LastSeen: time.Now()},
		{ID: "anon-1", AccountID: "", LastSeen: time.Now()},
	} {
		if err := st.UpsertProvider(context.Background(), rec); err != nil {
			t.Fatalf("upsert: %v", err)
		}
	}

	for _, tc := range []struct {
		user *store.User
		want []string
	}{
		{alice, []string{"alice-1", "alice-2"}},
		{bob, []string{"bob-1"}},
	} {
		r := authedReq(http.MethodGet, "/v1/me/providers", tc.user)
		w := httptest.NewRecorder()
		srv.handleMyProviders(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("%s: status = %d", tc.user.AccountID, w.Code)
		}
		var resp myProvidersResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("%s: unmarshal: %v", tc.user.AccountID, err)
		}
		if len(resp.Providers) != len(tc.want) {
			t.Fatalf("%s: got %d providers, want %d", tc.user.AccountID, len(resp.Providers), len(tc.want))
		}
		for i, want := range tc.want {
			if resp.Providers[i].ID != want {
				t.Fatalf("%s: provider[%d].id = %q, want %q",
					tc.user.AccountID, i, resp.Providers[i].ID, want)
			}
		}
	}
}

// TestMyProviders_LiveMachineMergedOverPersisted checks that when a machine
// is both persisted and currently connected, the live snapshot's status,
// system metrics, and warm models override the stale persisted view.
func TestMyProviders_LiveMachineMergedOverPersisted(t *testing.T) {
	srv, st, reg, user := testMeServer(t)

	// Persist a stale "offline" record first.
	hwJSON, _ := json.Marshal(protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64})
	modelsJSON, _ := json.Marshal([]protocol.ModelInfo{{ID: "model-a"}})
	rec := store.ProviderRecord{
		ID:        "live-machine",
		AccountID: user.AccountID,
		Hardware:  hwJSON,
		Models:    modelsJSON,
		Version:   "0.3.10",
		LastSeen:  time.Now().Add(-1 * time.Hour),
	}
	if err := st.UpsertProvider(context.Background(), rec); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	// Add a live registry entry with the same ID, attribute it to alice, and
	// give it warm models + system metrics so we can confirm they leak through.
	regMsg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "model-a"}},
		Backend:  "vllm-mlx",
		Version:  "0.3.10",
	}
	live := reg.Register("live-machine", nil, regMsg)
	live.Mu().Lock()
	live.AccountID = user.AccountID
	live.Status = registry.StatusOnline
	live.WarmModels = []string{"model-a"}
	live.CurrentModel = "model-a"
	live.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.4,
		CPUUsage:       0.2,
		ThermalState:   "nominal",
	}
	live.LastChallengeVerified = time.Now()
	live.RuntimeVerified = true
	live.TrustLevel = registry.TrustHardware
	live.Attested = true
	live.Mu().Unlock()

	r := authedReq(http.MethodGet, "/v1/me/providers", user)
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	var resp myProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Providers) != 1 {
		t.Fatalf("len = %d, want 1 (live and stored should merge, not duplicate)", len(resp.Providers))
	}
	got := resp.Providers[0]
	if got.Status != string(registry.StatusOnline) {
		t.Fatalf("status = %q, want online (live overrides persisted offline)", got.Status)
	}
	if !got.Online {
		t.Fatal("online should be true")
	}
	if got.LastHeartbeat == nil {
		t.Fatal("last_heartbeat should be present for live machine")
	}
	if got.SystemMetrics == nil || got.SystemMetrics.ThermalState != "nominal" {
		t.Fatalf("system_metrics not populated correctly: %+v", got.SystemMetrics)
	}
	if got.CurrentModel != "model-a" {
		t.Fatalf("current_model = %q, want model-a", got.CurrentModel)
	}
}

// TestMyProviders_ReconnectDoesNotDuplicate covers the case where a physical
// machine reconnected after the coordinator restarted, leaving an old
// ProviderRecord with the previous session ID and creating a new one with
// the current session ID. The dashboard must collapse them by stable identity
// (serial / SE pubkey) so the user sees one card per machine, not two.
func TestMyProviders_ReconnectDoesNotDuplicate(t *testing.T) {
	srv, st, _, user := testMeServer(t)

	const serial = "C02XYZ1234"
	hwJSON, _ := json.Marshal(protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64})
	modelsJSON, _ := json.Marshal([]protocol.ModelInfo{{ID: "model-a"}})

	// First session: stale record from before the coordinator restart.
	old := store.ProviderRecord{
		ID:           "session-old",
		AccountID:    user.AccountID,
		Hardware:     hwJSON,
		Models:       modelsJSON,
		SerialNumber: serial,
		LastSeen:     time.Now().Add(-2 * time.Hour),
	}
	// Second session: same physical machine reconnected — new ID, same serial.
	current := store.ProviderRecord{
		ID:           "session-new",
		AccountID:    user.AccountID,
		Hardware:     hwJSON,
		Models:       modelsJSON,
		SerialNumber: serial,
		LastSeen:     time.Now(),
	}
	for _, rec := range []store.ProviderRecord{old, current} {
		if err := st.UpsertProvider(context.Background(), rec); err != nil {
			t.Fatalf("upsert: %v", err)
		}
	}

	r := authedReq(http.MethodGet, "/v1/me/providers", user)
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	var resp myProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Providers) != 1 {
		t.Fatalf("got %d providers, want 1 (reconnect duplicates should collapse)", len(resp.Providers))
	}
	if resp.Providers[0].ID != "session-new" {
		t.Fatalf("kept ID = %q, want session-new (most recent LastSeen)", resp.Providers[0].ID)
	}
}

// TestMyProviders_LiveOnlyMachineAppears covers the race where a provider has
// just connected and not yet been persisted: we should still surface it.
func TestMyProviders_LiveOnlyMachineAppears(t *testing.T) {
	srv, _, reg, user := testMeServer(t)

	regMsg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M2", MemoryGB: 24},
	}
	live := reg.Register("fresh-machine", nil, regMsg)
	live.Mu().Lock()
	live.AccountID = user.AccountID
	live.Mu().Unlock()

	r := authedReq(http.MethodGet, "/v1/me/providers", user)
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	var resp myProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Providers) != 1 || resp.Providers[0].ID != "fresh-machine" {
		t.Fatalf("expected fresh-machine, got %+v", resp.Providers)
	}
}

// TestMyProviders_EarningsAttached covers the SE-public-key earnings join.
func TestMyProviders_EarningsAttached(t *testing.T) {
	srv, st, _, user := testMeServer(t)

	const sePub = "se-pubkey-base64-fingerprint"
	hwJSON, _ := json.Marshal(protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64})
	modelsJSON, _ := json.Marshal([]protocol.ModelInfo{})
	rec := store.ProviderRecord{
		ID:          "alice-earner",
		AccountID:   user.AccountID,
		Hardware:    hwJSON,
		Models:      modelsJSON,
		SEPublicKey: sePub,
		LastSeen:    time.Now(),
	}
	if err := st.UpsertProvider(context.Background(), rec); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	for i := 0; i < 3; i++ {
		if err := st.RecordProviderEarning(&store.ProviderEarning{
			AccountID:      user.AccountID,
			ProviderID:     "alice-earner",
			ProviderKey:    sePub,
			JobID:          "job-x",
			AmountMicroUSD: 100_000,
			CreatedAt:      time.Now(),
		}); err != nil {
			t.Fatalf("record earning: %v", err)
		}
	}

	r := authedReq(http.MethodGet, "/v1/me/providers", user)
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, r)

	var resp myProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Providers) != 1 {
		t.Fatalf("len = %d", len(resp.Providers))
	}
	got := resp.Providers[0]
	if got.EarningsCount != 3 {
		t.Fatalf("earnings_count = %d, want 3", got.EarningsCount)
	}
	if got.EarningsTotalMicroUSD != 300_000 {
		t.Fatalf("earnings_total_micro_usd = %d, want 300000", got.EarningsTotalMicroUSD)
	}
}

// --- /v1/me/summary ---

func TestMySummary_RequiresPrivyAuth(t *testing.T) {
	srv, _, _, _ := testMeServer(t)
	r := httptest.NewRequest(http.MethodGet, "/v1/me/summary", nil)
	r = r.WithContext(context.WithValue(r.Context(), ctxKeyConsumer, "api-key-only"))
	w := httptest.NewRecorder()
	srv.handleMySummary(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", w.Code)
	}
}

func TestMySummary_EmptyAccount(t *testing.T) {
	srv, _, _, user := testMeServer(t)
	r := authedReq(http.MethodGet, "/v1/me/summary", user)
	w := httptest.NewRecorder()
	srv.handleMySummary(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	var resp mySummaryResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.AccountID != user.AccountID {
		t.Fatalf("account_id = %q", resp.AccountID)
	}
	if resp.LifetimeMicroUSD != 0 || resp.LifetimeJobs != 0 {
		t.Fatalf("expected zero earnings, got %+v", resp)
	}
	if resp.Counts.Total != 0 {
		t.Fatalf("counts.total = %d, want 0", resp.Counts.Total)
	}
}

func TestMySummary_BucketsEarningsAndCountsFleet(t *testing.T) {
	srv, st, _, user := testMeServer(t)

	now := time.Now()
	earnings := []store.ProviderEarning{
		{AccountID: user.AccountID, ProviderKey: "k", JobID: "old", AmountMicroUSD: 1_000_000, CreatedAt: now.Add(-30 * 24 * time.Hour)},
		{AccountID: user.AccountID, ProviderKey: "k", JobID: "5d", AmountMicroUSD: 500_000, CreatedAt: now.Add(-5 * 24 * time.Hour)},
		{AccountID: user.AccountID, ProviderKey: "k", JobID: "12h", AmountMicroUSD: 200_000, CreatedAt: now.Add(-12 * time.Hour)},
		{AccountID: user.AccountID, ProviderKey: "k", JobID: "1m", AmountMicroUSD: 50_000, CreatedAt: now.Add(-time.Minute)},
	}
	for _, e := range earnings {
		if err := st.CreditProviderAccount(&e); err != nil {
			t.Fatalf("credit: %v", err)
		}
	}

	// Fleet: one healthy hardware-trust online machine, one stale offline,
	// one untrusted machine. Then check counts.
	healthy := store.ProviderRecord{
		ID:              "healthy",
		AccountID:       user.AccountID,
		TrustLevel:      "hardware",
		RuntimeVerified: true,
		Version:         "0.3.10",
		LastSeen:        now,
	}
	offline := store.ProviderRecord{
		ID:              "offline",
		AccountID:       user.AccountID,
		TrustLevel:      "hardware",
		RuntimeVerified: true,
		Version:         "0.3.10",
		LastSeen:        now.Add(-10 * time.Hour),
	}
	selfSigned := store.ProviderRecord{
		ID:              "self-signed",
		AccountID:       user.AccountID,
		TrustLevel:      "self_signed",
		RuntimeVerified: true,
		Version:         "0.3.10",
		LastSeen:        now,
	}
	for _, rec := range []store.ProviderRecord{healthy, offline, selfSigned} {
		if err := st.UpsertProvider(context.Background(), rec); err != nil {
			t.Fatalf("upsert: %v", err)
		}
	}

	r := authedReq(http.MethodGet, "/v1/me/summary", user)
	w := httptest.NewRecorder()
	srv.handleMySummary(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	var resp mySummaryResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.LifetimeMicroUSD != 1_750_000 {
		t.Fatalf("lifetime = %d, want 1750000", resp.LifetimeMicroUSD)
	}
	if resp.Last7dMicroUSD != 750_000 {
		t.Fatalf("last_7d = %d, want 750000 (5d + 12h + 1m)", resp.Last7dMicroUSD)
	}
	if resp.Last24hMicroUSD != 250_000 {
		t.Fatalf("last_24h = %d, want 250000 (12h + 1m)", resp.Last24hMicroUSD)
	}
	if resp.AvailableBalanceMicroUSD != 1_750_000 {
		t.Fatalf("available_balance = %d, want 1750000", resp.AvailableBalanceMicroUSD)
	}
	if resp.Counts.Total != 3 {
		t.Fatalf("counts.total = %d, want 3", resp.Counts.Total)
	}
	if resp.Counts.Hardware != 2 {
		t.Fatalf("counts.hardware = %d, want 2", resp.Counts.Hardware)
	}
	if resp.Counts.Offline < 1 {
		t.Fatalf("counts.offline = %d, want at least 1", resp.Counts.Offline)
	}
	if resp.Counts.NeedsAttn < 2 {
		t.Fatalf("counts.needs_attention = %d, want >= 2 (offline + self_signed)",
			resp.Counts.NeedsAttn)
	}
}
