package baserewards

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

// engineStore is a store.Store test double: it serves seeded sessions and
// earnings (with explicit timestamps the engine math depends on) while
// delegating all settlement bookkeeping — the idempotent floor-draw row and the
// balance credit — to a real *store.MemoryStore. This keeps the
// idempotency/credit semantics exact (the production memory impl) while letting
// the test control session/earnings inputs deterministically. The store's own
// SQL-level correctness is covered separately by store/base_rewards_test.go.
type engineStore struct {
	store.Store // embedded: any method the engine does not call panics if hit
	inner       *store.MemoryStore
	sessions    []store.ProviderSession
	earnings    []store.ProviderEarning // organic earning rows, keyed by ProviderKey
	probed      map[string]bool         // providerKey → passed a probe in-window (gate-5 OR)
}

func newEngineStore() *engineStore {
	return &engineStore{inner: store.NewMemory(store.Config{}), probed: map[string]bool{}}
}

func (s *engineStore) ListProviderSessionsOverlapping(_ context.Context, start, end time.Time) ([]store.ProviderSession, error) {
	out := []store.ProviderSession{}
	for _, ps := range s.sessions {
		sessEnd := ps.LastSeen
		if ps.DisconnectedAt != nil {
			sessEnd = *ps.DisconnectedAt
		}
		if ps.ConnectedAt.Before(end) && !sessEnd.Before(start) {
			out = append(out, ps)
		}
	}
	return out, nil
}

func (s *engineStore) SumProviderEarningsByKey(_ context.Context, providerKey string, since, until time.Time) (int64, error) {
	var total int64
	for _, e := range s.earnings {
		if e.ProviderKey != providerKey || e.AmountMicroUSD <= 0 {
			continue
		}
		if e.Model == "base_reward" || e.Model == "probe" {
			continue
		}
		if e.CreatedAt.Before(since) || !e.CreatedAt.Before(until) {
			continue
		}
		total += e.AmountMicroUSD
	}
	return total, nil
}

func (s *engineStore) HasBilledJobSince(_ context.Context, providerKey string, since time.Time) (bool, error) {
	for _, e := range s.earnings {
		if e.ProviderKey != providerKey || e.AmountMicroUSD <= 0 {
			continue
		}
		if e.Model == "base_reward" || e.Model == "probe" {
			continue
		}
		if !e.CreatedAt.Before(since) {
			return true, nil
		}
	}
	return false, nil
}

func (s *engineStore) HasProbeSuccessSince(providerKey string, _ time.Time) (bool, error) {
	return s.probed[providerKey], nil
}

func (s *engineStore) WithEpochSettlementLock(_ context.Context, _ string, fn func() error) error {
	return fn()
}

// Settlement bookkeeping delegates to the real memory store.
func (s *engineStore) SettleProviderFloorDraw(ctx context.Context, draw *store.ProviderFloorDraw) (bool, error) {
	return s.inner.SettleProviderFloorDraw(ctx, draw)
}
func (s *engineStore) SumFloorDrawsForEpoch(ctx context.Context, epochID string) (int64, error) {
	return s.inner.SumFloorDrawsForEpoch(ctx, epochID)
}
func (s *engineStore) ListFloorDrawsForEpoch(ctx context.Context, epochID string) ([]store.ProviderFloorDraw, error) {
	return s.inner.ListFloorDrawsForEpoch(ctx, epochID)
}

func (s *engineStore) balance(accountID string) (int64, int64) {
	return s.inner.GetBalanceWithWithdrawable(accountID)
}

// --- registry helpers ---

// addProvider registers an eligible-by-default provider on reg and returns its
// live pointer so the test can override individual gate fields.
func addProvider(reg *registry.Registry, id, providerKey, serial, hardwareModel string, memGB int) *registry.Provider {
	msg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{MachineModel: hardwareModel, MemoryGB: memGB},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               providerKey,
		EncryptedResponseChunks: true,
	}
	p := reg.Register(id, nil, msg)
	// Register clears PublicKey unless it is a valid 32-byte base64 X25519 key;
	// the engine identifies machines by it, so set it directly on the live
	// pointer (the test seeds matching sessions/earnings under the same key).
	p.PublicKey = providerKey
	p.Attested = true
	p.TrustLevel = registry.TrustHardware
	p.CurrentModel = "test-model" // model loaded for routing (gate 4)
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, ThermalState: "nominal"}
	return p
}

// setSerial attaches the SE-signed serial + hardware model the registry snapshot
// reads from AttestationResult.
func setSerial(p *registry.Provider, serial, hardwareModel string) {
	p.AttestationResult = &attestation.VerificationResult{
		SerialNumber:  serial,
		HardwareModel: hardwareModel,
	}
}

// epoch helpers: pick a fully-closed past epoch and a clock just after it.
func closedEpoch() (epochID string, start, end, clock time.Time) {
	// Use a fixed month well in the past so it is always closed.
	start = time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	end = start.AddDate(0, 1, 0)
	clock = end.Add(48 * time.Hour) // safely after epoch close
	return "2025-01", start, end, clock
}

// fullUptimeSession returns a closed session covering the entire epoch.
func fullUptimeSession(id, providerKey, serial, account string, start, end time.Time) store.ProviderSession {
	disc := end
	return store.ProviderSession{
		SessionID:      id,
		SerialNumber:   serial,
		AccountID:      account,
		ProviderKey:    providerKey,
		ConnectedAt:    start,
		LastSeen:       end,
		DisconnectedAt: &disc,
	}
}

func organicEarning(providerKey, account, jobID string, amount int64, when time.Time) store.ProviderEarning {
	return store.ProviderEarning{
		AccountID:      account,
		ProviderKey:    providerKey,
		JobID:          jobID,
		Model:          "test-model",
		AmountMicroUSD: amount,
		CreatedAt:      when,
	}
}

func newTestEngine(st store.Store, reg *registry.Registry, clock time.Time) *Engine {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.PerAccountCapFrac = 0 // disable the cap unless a test sets it
	e := NewEngine(st, reg, cfg, testLogger())
	e.now = func() time.Time { return clock }
	return e
}

func TestSettleEpoch_Disabled(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	p := addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	setSerial(p, "S1", "Mac15,8")
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 1_000_000, start.Add(time.Hour))}

	cfg := DefaultConfig() // Enabled=false
	e := NewEngine(st, reg, cfg, testLogger())
	e.now = func() time.Time { return clock }

	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Settled != 0 || res.Eligible != 0 {
		t.Fatalf("disabled engine must be a no-op, got %+v", res)
	}
	if bal, _ := st.balance("acc1"); bal != 0 {
		t.Fatalf("disabled engine credited %d, want 0", bal)
	}
}

func TestSettleEpoch_EpochNotClosed(t *testing.T) {
	epochID, start, end, _ := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	p := addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	setSerial(p, "S1", "Mac15,8")
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 1_000_000, start.Add(time.Hour))}

	// Clock is mid-epoch → not closed.
	e := newTestEngine(st, reg, start.Add(10*24*time.Hour))
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Settled != 0 {
		t.Fatalf("open epoch must not settle, got %+v", res)
	}
}

// TestSettleEpoch_MemoryCapPreventsOverclaim proves the anti-gaming property:
// a small machine that self-reports a huge memory tier is clamped DOWN to the
// max its SE-signed hardware model ever shipped, so it cannot bank a higher
// tier's floor. A 16GB MacBook Air claiming 512GB earns $0, not $40.
func TestSettleEpoch_MemoryCapPreventsOverclaim(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	p := addProvider(reg, "air", "PKair", "Sair", "MacBookAir10,1", 512) // lies: 512GB
	setSerial(p, "Sair", "MacBookAir10,1")                               // cap = 16GB
	st.sessions = []store.ProviderSession{fullUptimeSession("air", "PKair", "Sair", "accAir", start, end)}
	st.earnings = []store.ProviderEarning{organicEarning("PKair", "consumer", "j1", 1_000_000, start.Add(time.Hour))}

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.TotalDrawMicroUSD != 0 {
		t.Fatalf("overclaimed Air should draw 0 after memory cap, got %d", res.TotalDrawMicroUSD)
	}
	if bal, _ := st.balance("accAir"); bal != 0 {
		t.Fatalf("overclaimed Air credited %d, want 0 (cap rejects the 512GB claim)", bal)
	}
}

func TestSettleEpoch_HappyPathAndIdempotent(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	p := addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	setSerial(p, "S1", "Mac15,8")
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	// $5 organic + 64GB floor $18, additive (k=0) → full $18 base reward on top.
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 5_000_000, start.Add(time.Hour))}

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Settled != 1 || res.TotalDrawMicroUSD != 18_000_000 {
		t.Fatalf("happy path: got %+v, want 1 settled / 18_000_000 draw (additive full floor)", res)
	}
	if bal, wd := st.balance("acc1"); bal != 18_000_000 || wd != 18_000_000 {
		t.Fatalf("credit: balance=%d withdrawable=%d, want 18_000_000 each", bal, wd)
	}

	// Re-run (same store) → idempotent, no double credit.
	res2, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res2.Settled != 0 || res2.AlreadySettled != 1 {
		t.Fatalf("idempotent re-run: got %+v, want 0 settled / 1 already", res2)
	}
	if bal, _ := st.balance("acc1"); bal != 18_000_000 {
		t.Fatalf("re-run double-credited: balance=%d", bal)
	}
}

func TestSettleEpoch_RestartSafe(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	p := addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	setSerial(p, "S1", "Mac15,8")
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	// A billed job served just BEFORE the epoch (within the 45d work window)
	// satisfies the proven-work gate but contributes $0 to this epoch's earned →
	// the machine draws its full $18 floor.
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 2_000_000, start.Add(-24*time.Hour))}

	e1 := newTestEngine(st, reg, clock)
	if _, err := e1.SettleEpoch(context.Background(), epochID); err != nil {
		t.Fatal(err)
	}
	// A brand-new engine over the SAME store (simulates a restart / blue-green
	// second instance) must not credit again.
	e2 := newTestEngine(st, reg, clock)
	res, err := e2.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Settled != 0 || res.AlreadySettled != 1 {
		t.Fatalf("restart: got %+v, want 0 settled / 1 already", res)
	}
	if bal, _ := st.balance("acc1"); bal != 18_000_000 {
		t.Fatalf("restart double-credited: balance=%d, want 18_000_000", bal)
	}
}

func TestSettleEpoch_PreAttestationUnpaid(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	p := addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	setSerial(p, "S1", "Mac15,8")
	p.Attested = false // un-attested → gate 1 fails
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 1_000_000, start.Add(time.Hour))}

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Eligible != 0 || res.Settled != 0 {
		t.Fatalf("un-attested must earn $0, got %+v", res)
	}
}

func TestSettleEpoch_SelfRouteExcluded(t *testing.T) {
	// Self-route produces no billed earning row, so the proven-work gate (gate 5)
	// is never satisfied. Zero organic earnings + a full-uptime session → fails
	// the work gate → $0, even though uptime is perfect.
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	p := addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	setSerial(p, "S1", "Mac15,8")
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	st.earnings = nil // self-route leaves no billed earning row

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Eligible != 0 || res.Settled != 0 {
		t.Fatalf("no billed work → no floor, got %+v", res)
	}
}

func TestSettleEpoch_PartialSettlement_SumEqualsPool(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())

	// Many idle workhorses, each wanting the full $18 floor, over-subscribing a
	// tiny pool. Σ granted must equal the pool exactly.
	const n = 10
	budget := int64(50_000_000) // far below n*18M demand
	for i := 0; i < n; i++ {
		pk := "PK" + string(rune('A'+i))
		acc := "acc" + string(rune('A'+i))
		p := addProvider(reg, "p"+string(rune('A'+i)), pk, pk, "Mac15,8", 64)
		setSerial(p, pk, "Mac15,8")
		st.sessions = append(st.sessions, fullUptimeSession("p"+pk, pk, pk, acc, start, end))
		st.earnings = append(st.earnings, organicEarning(pk, "consumer", "j"+pk, 1_000_000, start.Add(time.Hour)))
	}

	e := newTestEngine(st, reg, clock)
	e.cfg.PoolBudgetMicroUSD = budget
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Eligible != n {
		t.Fatalf("eligible=%d, want %d", res.Eligible, n)
	}
	if res.TotalDrawMicroUSD != budget {
		t.Fatalf("over-subscribed Σ granted = %d, want exactly pool %d", res.TotalDrawMicroUSD, budget)
	}
	used, _ := st.SumFloorDrawsForEpoch(context.Background(), epochID)
	if used != budget {
		t.Fatalf("settled pool used = %d, want %d", used, budget)
	}
}

func TestSettleEpoch_EmptyFleet_NoNaN(t *testing.T) {
	epochID, _, _, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Eligible != 0 || res.Settled != 0 || res.TotalDrawMicroUSD != 0 {
		t.Fatalf("empty fleet must be a clean zero, got %+v", res)
	}
}

func TestSettleEpoch_BlueGreenDoubleOpen(t *testing.T) {
	// Two overlapping open sessions for one machine (blue-green deploy) must union
	// to at most 100% uptime — never >1.0, which would over-pay the floor.
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	p := addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	setSerial(p, "S1", "Mac15,8")

	// Two sessions, each covering most of the epoch, heavily overlapping. Closed
	// at end so they fully cover the month.
	half := start.Add(end.Sub(start) / 2)
	disc := end
	s1 := store.ProviderSession{SessionID: "s1", SerialNumber: "S1", AccountID: "acc1", ProviderKey: "PK1", ConnectedAt: start, LastSeen: end, DisconnectedAt: &disc}
	s2 := store.ProviderSession{SessionID: "s2", SerialNumber: "S1", AccountID: "acc1", ProviderKey: "PK1", ConnectedAt: half, LastSeen: end, DisconnectedAt: &disc}
	st.sessions = []store.ProviderSession{s1, s2}
	// Billed job before the epoch satisfies the work gate; $0 earned this epoch →
	// full floor, so the test isolates the uptime-cap behavior.
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 2_000_000, start.Add(-24*time.Hour))}

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Settled != 1 {
		t.Fatalf("expected one settlement, got %+v", res)
	}
	// Full coverage (not 150%) → exactly the $18 floor for the 64GB tier.
	if res.TotalDrawMicroUSD != 18_000_000 {
		t.Fatalf("double-open over-paid: draw=%d, want 18_000_000 (uptime capped at 1.0)", res.TotalDrawMicroUSD)
	}
}

func TestSettleEpoch_BelowUptimeGate(t *testing.T) {
	// 80% uptime is below the 90% hard gate → $0.
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := registry.New(testLogger())
	p := addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	setSerial(p, "S1", "Mac15,8")

	covered := time.Duration(float64(end.Sub(start)) * 0.80)
	disc := start.Add(covered)
	st.sessions = []store.ProviderSession{{
		SessionID: "s1", SerialNumber: "S1", AccountID: "acc1", ProviderKey: "PK1",
		ConnectedAt: start, LastSeen: disc, DisconnectedAt: &disc,
	}}
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 0, start.Add(time.Hour))}

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Eligible != 0 {
		t.Fatalf("80%% uptime should fail the 90%% gate, got %+v", res)
	}
}

func TestUptimeByProviderKey_OpenSessionGrace(t *testing.T) {
	_, start, end, _ := closedEpoch()
	cfg := DefaultConfig()
	cfg.GraceSeconds = 90
	e := &Engine{cfg: cfg, now: func() time.Time { return end.Add(time.Hour) }}

	// Open session (no DisconnectedAt), last_seen 1h before epoch end. It should
	// accrue only to last_seen + 90s, NOT to epoch end.
	lastSeen := end.Add(-time.Hour)
	sessions := []store.ProviderSession{{
		SessionID: "s1", ProviderKey: "PK1", ConnectedAt: start, LastSeen: lastSeen,
	}}
	frac := e.uptimeByProviderKey(sessions, start, end)["PK1"]

	total := end.Sub(start).Seconds()
	wantCovered := lastSeen.Add(90 * time.Second).Sub(start).Seconds()
	want := wantCovered / total
	if diff := frac - want; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("open-session grace: frac=%v, want %v", frac, want)
	}
}
