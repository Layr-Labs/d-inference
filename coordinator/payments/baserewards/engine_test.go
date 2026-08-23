package baserewards

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

// engineStore implements only the persistence operations the settlement engine
// collaborates with. Durable credit/idempotency behavior is delegated to the
// memory store, whose backend contract is covered in the store package.
type engineStore struct {
	inner    *store.MemoryStore
	sessions []store.ProviderSession
	earnings []store.ProviderEarning
}

func newEngineStore() *engineStore {
	return &engineStore{inner: store.NewMemory(store.Config{})}
}

func (s *engineStore) ListProviderSessionsOverlapping(_ context.Context, start, end time.Time, openSessionGrace time.Duration) ([]store.ProviderSession, error) {
	out := []store.ProviderSession{}
	for _, ps := range s.sessions {
		sessEnd := ps.LastSeen
		if ps.DisconnectedAt != nil {
			sessEnd = *ps.DisconnectedAt
		} else {
			sessEnd = ps.LastSeen.Add(openSessionGrace)
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
		if e.Model == "base_reward" {
			continue
		}
		if e.CreatedAt.Before(since) || !e.CreatedAt.Before(until) {
			continue
		}
		total += e.AmountMicroUSD
	}
	return total, nil
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

type engineRegistry struct {
	providers []registry.ProviderSnapshot
}

func newEngineRegistry() *engineRegistry {
	return &engineRegistry{}
}

func (r *engineRegistry) ListProviders() []registry.ProviderSnapshot {
	return append([]registry.ProviderSnapshot(nil), r.providers...)
}

func (r *engineRegistry) TrustMeetsMinimum(level registry.TrustLevel) bool {
	return level == registry.TrustHardware
}

func addProvider(reg *engineRegistry, id, providerKey, serial, hardwareModel string, memGB int) *registry.ProviderSnapshot {
	reg.providers = append(reg.providers, registry.ProviderSnapshot{
		ID:             id,
		ProviderKey:    providerKey,
		SerialNumber:   serial,
		HardwareModel:  hardwareModel,
		MemoryGB:       memGB,
		TrustLevel:     registry.TrustHardware,
		Attested:       true,
		Online:         true,
		ModelLoaded:    true,
		CurrentModel:   "test-model",
		MemoryPressure: 0.1,
		ThermalState:   "nominal",
	})
	return &reg.providers[len(reg.providers)-1]
}

// epoch helpers: pick a fully-closed past settlement period and a clock just
// after it.
func closedEpoch() (epochID string, start, end, clock time.Time) {
	// Use a fixed 5-minute period well in the past so it is always closed.
	start = time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	end = start.Add(SettlementPeriod)
	clock = end.Add(10 * time.Minute) // safely after period close
	return start.Format(periodIDLayout), start, end, clock
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

func newTestEngine(st settlementStore, reg providerRegistry, clock time.Time) *Engine {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.PerAccountCapFrac = 0 // disable the cap unless a test sets it
	e := newEngine(st, reg, cfg, testLogger())
	e.now = func() time.Time { return clock }
	return e
}

func TestSettleEpoch_Disabled(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := newEngineRegistry()
	addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 1_000_000, start.Add(time.Hour))}

	cfg := DefaultConfig() // Enabled=false
	e := newEngine(st, reg, cfg, testLogger())
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
	reg := newEngineRegistry()
	addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 1_000_000, start.Add(time.Hour))}

	// Clock is mid-period → not closed.
	e := newTestEngine(st, reg, start.Add(time.Minute))
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
	reg := newEngineRegistry()
	addProvider(reg, "air", "PKair", "Sair", "MacBookAir10,1", 512) // lies: 512GB
	                               // cap = 16GB
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

func TestSettleEpoch_UnknownHardwareModelUnpaid(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := newEngineRegistry()
	addProvider(reg, "unknown", "PKunknown", "Sunknown", "Mac99,1", 512)
	
	st.sessions = []store.ProviderSession{fullUptimeSession("unknown", "PKunknown", "Sunknown", "accUnknown", start, end)}
	st.earnings = []store.ProviderEarning{organicEarning("PKunknown", "consumer", "j1", 1_000_000, start.Add(time.Minute))}

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Eligible != 0 {
		t.Fatalf("unknown hardware model should be ineligible, got eligible=%d", res.Eligible)
	}
	if res.TotalDrawMicroUSD != 0 {
		t.Fatalf("unknown hardware model should draw 0, got %d", res.TotalDrawMicroUSD)
	}
	if bal, _ := st.balance("accUnknown"); bal != 0 {
		t.Fatalf("unknown hardware model credited %d, want 0", bal)
	}
}

func TestSettleEpoch_HappyPathAndIdempotent(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := newEngineRegistry()
	addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	// $5 organic + 64GB floor $18/mo, additive (k=0) → full prorated 5-minute
	// base reward on top.
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 5_000_000, start.Add(time.Minute))}

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	want := PeriodFloor(64, 1.0, start, end)
	if res.Settled != 1 || res.TotalDrawMicroUSD != want {
		t.Fatalf("happy path: got %+v, want 1 settled / %d draw (additive prorated floor)", res, want)
	}
	if bal, wd := st.balance("acc1"); bal != want || wd != want {
		t.Fatalf("credit: balance=%d withdrawable=%d, want %d each", bal, wd, want)
	}

	// Re-run (same store) → idempotent, no double credit.
	res2, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res2.Settled != 0 || res2.AlreadySettled != 1 {
		t.Fatalf("idempotent re-run: got %+v, want 0 settled / 1 already", res2)
	}
	if bal, _ := st.balance("acc1"); bal != want {
		t.Fatalf("re-run double-credited: balance=%d", bal)
	}
}

func TestSettleEpoch_RestartSafe(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := newEngineRegistry()
	addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	// A prior job contributes $0 to this period's earned; eligibility no longer
	// depends on demand, so the machine draws its prorated floor.
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
	want := PeriodFloor(64, 1.0, start, end)
	if bal, _ := st.balance("acc1"); bal != want {
		t.Fatalf("restart double-credited: balance=%d, want %d", bal, want)
	}
}

func TestSettleEpoch_PreAttestationUnpaid(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := newEngineRegistry()
	addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	
	reg.providers[0].Attested = false // un-attested → gate 1 fails
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

func TestSettleEpoch_NoDemandStillPaid(t *testing.T) {
	// Base rewards are demand-independent: zero organic earnings + a full-uptime
	// eligible session still earns the prorated floor.
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := newEngineRegistry()
	addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	
	st.sessions = []store.ProviderSession{fullUptimeSession("p1", "PK1", "S1", "acc1", start, end)}
	st.earnings = nil // self-route leaves no billed earning row

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	want := PeriodFloor(64, 1.0, start, end)
	if res.Eligible != 1 || res.Settled != 1 || res.TotalDrawMicroUSD != want {
		t.Fatalf("no demand should still pay prorated floor %d, got %+v", want, res)
	}
}

func TestSettleEpoch_PartialSettlement_SumEqualsPool(t *testing.T) {
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := newEngineRegistry()

	// Many idle workhorses, each wanting the full $18 floor, over-subscribing a
	// tiny pool. Σ granted must equal the pool exactly.
	const n = 10
	budget := int64(50_000_000) // monthly pool; prorated period budget is below demand
	for i := range n {
		pk := "PK" + string(rune('A'+i))
		acc := "acc" + string(rune('A'+i))
		addProvider(reg, "p"+string(rune('A'+i)), pk, pk, "Mac15,8", 64)
		
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
	wantBudget := PeriodBudget(budget, start, end)
	if res.TotalDrawMicroUSD != wantBudget {
		t.Fatalf("over-subscribed Σ granted = %d, want exactly period pool %d", res.TotalDrawMicroUSD, wantBudget)
	}
	used, err := st.SumFloorDrawsForEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatalf("sum settled draws: %v", err)
	}
	if used != wantBudget {
		t.Fatalf("settled pool used = %d, want %d", used, wantBudget)
	}
}

func TestSettleEpoch_EmptyFleet_NoNaN(t *testing.T) {
	epochID, _, _, clock := closedEpoch()
	st := newEngineStore()
	reg := newEngineRegistry()
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
	reg := newEngineRegistry()
	addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	

	// Two sessions, each covering most of the epoch, heavily overlapping. Closed
	// at end so they fully cover the period.
	half := start.Add(end.Sub(start) / 2)
	disc := end
	s1 := store.ProviderSession{SessionID: "s1", SerialNumber: "S1", AccountID: "acc1", ProviderKey: "PK1", ConnectedAt: start, LastSeen: end, DisconnectedAt: &disc}
	s2 := store.ProviderSession{SessionID: "s2", SerialNumber: "S1", AccountID: "acc1", ProviderKey: "PK1", ConnectedAt: half, LastSeen: end, DisconnectedAt: &disc}
	st.sessions = []store.ProviderSession{s1, s2}
	// $0 earned this period → prorated floor, so the test isolates the uptime-cap
	// behavior without depending on demand.
	st.earnings = []store.ProviderEarning{organicEarning("PK1", "consumer", "j1", 2_000_000, start.Add(-24*time.Hour))}

	e := newTestEngine(st, reg, clock)
	res, err := e.SettleEpoch(context.Background(), epochID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Settled != 1 {
		t.Fatalf("expected one settlement, got %+v", res)
	}
	// Full coverage (not 150%) → exactly the prorated 64GB floor.
	want := PeriodFloor(64, 1.0, start, end)
	if res.TotalDrawMicroUSD != want {
		t.Fatalf("double-open over-paid: draw=%d, want %d (uptime capped at 1.0)", res.TotalDrawMicroUSD, want)
	}
}

func TestSettleEpoch_BelowUptimeGate(t *testing.T) {
	// 80% uptime is below the 90% hard gate → $0.
	epochID, start, end, clock := closedEpoch()
	st := newEngineStore()
	reg := newEngineRegistry()
	addProvider(reg, "p1", "PK1", "S1", "Mac15,8", 64)
	

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

	// Open session (no DisconnectedAt), last_seen before period end. It should
	// accrue only to last_seen + 90s, NOT to period end.
	lastSeen := start.Add(2 * time.Minute)
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
