package registry

// Algorithm scenario tests — the bar the routing algorithm must clear.
//
// These tests encode the desired post-change behavior of the scheduler,
// independent of any single phase's implementation. They serve three
// purposes:
//
//   1. RED-then-GREEN signal during phased rollout. Scenarios that fail
//      today must turn green after their gating phase lands. A scenario
//      that flips back to red on a later phase signals a regression.
//
//   2. Spec for what "improvement" means. Each scenario carries a comment
//      naming the gap in the current algorithm and the phase that closes
//      it.
//
//   3. Regression guard for behaviors we already have right (e.g.
//      cold-slot avoidance, slot-state respect). Those scenarios should
//      stay green throughout.
//
// Phases (see plan in conversation):
//   P1 — Free-memory admission gate (CatalogEntry.SizeGB + KV estimate)
//   P2 — Tighter maxConcurrency caps
//   P3 — Stronger queue/pending penalties + wider near-tie window
//   P4 — Load-scaled effective decode TPS
//   P5 — Model-swap penalty
//
// Per scenario, we annotate the gating phase and the current expected
// pass/fail state at the time of writing. Run:
//
//   go test ./internal/registry/ -run TestAlgorithm_ -v
//
// to see which scenarios currently pass.

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// scenarioProvider builds a fully-attested provider with controllable
// hardware/memory/backend stats so each scenario can model a specific
// fleet shape without boilerplate.
type scenarioProvider struct {
	id          string
	decodeTPS   float64
	totalMemGB  float64
	gpuActiveGB float64
	pending     int    // coordinator-tracked pending (in-flight assigned)
	backendRun  int    // backend slot's NumRunning
	backendWait int    // backend slot's NumWaiting
	slotState   string // running, idle_shutdown, etc.
	conn        *websocket.Conn
}

func (sp scenarioProvider) register(t *testing.T, reg *Registry, model string) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = sp.decodeTPS
	msg.Hardware.MemoryGB = int(sp.totalMemGB)
	p := reg.Register(sp.id, sp.conn, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	state := sp.slotState
	if state == "" {
		state = "running"
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB:     sp.totalMemGB,
		GPUMemoryActiveGB: sp.gpuActiveGB,
		Slots: []protocol.BackendSlotCapacity{
			{
				Model:      model,
				State:      state,
				NumRunning: sp.backendRun,
				NumWaiting: sp.backendWait,
			},
		},
	}
	for i := 0; i < sp.pending; i++ {
		p.addPendingLocked(&PendingRequest{
			RequestID:          fmt.Sprintf("%s-pending-%d", sp.id, i),
			Model:              model,
			RequestedMaxTokens: 256,
		})
	}
	p.mu.Unlock()
	return p
}

func reserveOne(reg *Registry, model string, reqMax int) *Provider {
	pr := &PendingRequest{
		RequestID:          fmt.Sprintf("scenario-req-%d", time.Now().UnixNano()),
		Model:              model,
		RequestedMaxTokens: reqMax,
	}
	return reg.ReserveProvider(model, pr)
}

// ---------------------------------------------------------------------
// Phase 1 scenarios — free-memory admission gate
// ---------------------------------------------------------------------

// A 32 GB model on a 24 GB machine must be rejected at admission, even
// if the provider claims to serve the model. Today: we route to the
// only provider in the fleet because there is no free-memory check;
// the provider then OOMs trying to load.
//
// Phase 1 fix: providerCanAdmitLocked rejects when free memory < model
// size + KV estimate. Scenario will spawn a second, capable provider
// so a non-nil result is achievable post-fix.
func TestAlgorithm_P1_RejectsProviderTooSmallForModel(t *testing.T) {
	reg := New(testLogger())
	model := "needs-32gb-model"
	// Catalog says this model needs ~32 GB.
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 32}})

	// One small (24 GB) provider claiming to serve the model but not
	// currently running it (cold backend). With no memory gate, this
	// provider would be selected and then OOM trying to load the model.
	scenarioProvider{
		id: "small", decodeTPS: 30, totalMemGB: 24, gpuActiveGB: 1,
		slotState: "idle_shutdown",
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p != nil {
		t.Fatalf("EXPECTED rejection: 24 GB provider can't fit 32 GB model. "+
			"Got %q. Phase 1 (free-memory admission gate) not yet implemented.", p.ID)
	}
}

// When the only fitting provider is busy and the only idle provider
// is too small, the request must be queued (not routed to the small
// one). Today: the small provider gets the request despite OOM risk.
func TestAlgorithm_P1_PrefersBusyFitOverIdleNoFit(t *testing.T) {
	reg := New(testLogger())
	model := "p1-busy-vs-idle-model"
	// 32 GB model: only the 128 GB provider fits.
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 32}})

	scenarioProvider{
		id: "big-busy", decodeTPS: 80, totalMemGB: 128, gpuActiveGB: 50,
		pending: 1, backendRun: 1,
	}.register(t, reg, model)
	// Small provider has the model in its catalog but no slot loaded,
	// so the gate must compute weights + KV against free memory.
	scenarioProvider{
		id: "small-idle", decodeTPS: 20, totalMemGB: 24, gpuActiveGB: 1,
		slotState: "idle_shutdown",
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected the busy big provider to win, got nil")
	}
	if p.ID != "big-busy" {
		t.Fatalf("got %q, want big-busy. The small provider can't fit the model — Phase 1 must reject it.", p.ID)
	}
}

// A provider that ALREADY has the model loaded (slot.State == "running")
// only needs incremental KV space, not the full weights footprint.
// This guards against an over-eager gate that would reject a warm
// provider as "no room for the model" when the model is already
// resident.
func TestAlgorithm_P1_DoesNotRejectWarmProviderWithoutWeightsHeadroom(t *testing.T) {
	reg := New(testLogger())
	model := "p1-warm-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 32}})

	// 48 GB provider currently running the model with 35 GB of GPU
	// memory active (model + some KV). Free memory is 13 GB — far less
	// than the 32 GB model footprint. But the gate must accept this
	// provider because the weights are already resident.
	scenarioProvider{
		id: "warm-running", decodeTPS: 60, totalMemGB: 48, gpuActiveGB: 35,
		slotState: "running",
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected warm-running to be admitted (model already loaded), got nil")
	}
	if p.ID != "warm-running" {
		t.Fatalf("got %q, want warm-running", p.ID)
	}
}

// A model that is RESIDENT-but-idle (loaded, no active requests → provider
// reports slot state "idle", not "running") must never be rejected by the
// absolute-fit gate. The model is demonstrably in memory, so the heuristic —
// which can overestimate via catalog SizeGB — must not exclude it. Regression
// for the review finding: `snap.modelLoaded` only tracks "running", so an "idle"
// slot would otherwise be treated as a cold load and gated.
func TestAlgorithm_P1_IdleResidentModelNotRejectedByFitGate(t *testing.T) {
	reg := New(testLogger())
	model := "p1-idle-resident"
	// Catalog SizeGB=40 → fit gate needs 40*2.0=80 GB, more than the 64 GB box.
	// If the gate ignored residency it would reject this provider.
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 40}})

	scenarioProvider{
		id: "idle-resident", decodeTPS: 60, totalMemGB: 64, gpuActiveGB: 42,
		slotState: "idle", // loaded, currently no active requests
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected idle-resident provider to be admitted (model is loaded), got nil")
	}
	if p.ID != "idle-resident" {
		t.Fatalf("got %q, want idle-resident", p.ID)
	}
}

// When the catalog has no SizeGB for a model, the gate must not gate.
// This preserves backwards compatibility with catalog entries written
// before the SizeGB field existed.
func TestAlgorithm_P1_NoSizeInCatalogDisablesGate(t *testing.T) {
	reg := New(testLogger())
	model := "p1-unsized-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}}) // SizeGB unset

	// Tiny provider that would fail the gate if SizeGB were set.
	scenarioProvider{
		id: "tiny", decodeTPS: 20, totalMemGB: 8, gpuActiveGB: 7,
		slotState: "idle_shutdown",
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected tiny to be admitted (gate disabled when SizeGB=0), got nil")
	}
}

// ---------------------------------------------------------------------
// Phase 2 scenarios — tighter maxConcurrency caps
// ---------------------------------------------------------------------

// 512 GB Ultra currently has maxConcurrency=32. Phase 2 lowers tiers
// so a >128 GB machine caps at ~12. Concurrent requests beyond the new
// cap must spill to a smaller provider.
//
// We seed the Ultra with 12 in-flight requests; the 13th should go
// elsewhere. Today: 13th still fits in the 32-slot cap and stays.
func TestAlgorithm_P2_UltraSpillsAfterNewConcurrencyCap(t *testing.T) {
	reg := New(testLogger())
	model := "p2-cap-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{
		id: "ultra", decodeTPS: 100, totalMemGB: 512, gpuActiveGB: 50,
		pending: 12, backendRun: 12,
	}.register(t, reg, model)
	scenarioProvider{
		id: "max-128", decodeTPS: 60, totalMemGB: 128, gpuActiveGB: 5,
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected fallback to max-128, got nil")
	}
	if p.ID != "max-128" {
		t.Fatalf("got %q, want max-128. Phase 2 (lower maxConcurrency caps) not yet in effect.", p.ID)
	}
}

// ---------------------------------------------------------------------
// Phase 3 scenarios — stronger queue penalty / wider tie window
// ---------------------------------------------------------------------

// Big machine has 1 in-flight request. Small machine is fully idle.
// The new request is short (256 tokens). Today: big still wins
// because the per-request decode delta dwarfs queue penalty.
// Phase 3: queueDepthPenaltyMs ↑ should push small into the lead.
func TestAlgorithm_P3_OneBackedUpBigVsIdleSmall_SmallWins(t *testing.T) {
	reg := New(testLogger())
	model := "p3-queue-penalty-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{
		id: "ultra", decodeTPS: 80, totalMemGB: 512, gpuActiveGB: 30,
		pending: 1, backendRun: 1,
	}.register(t, reg, model)
	scenarioProvider{
		id: "pro-idle", decodeTPS: 20, totalMemGB: 24, gpuActiveGB: 1,
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected pro-idle, got nil")
	}
	if p.ID != "pro-idle" {
		t.Fatalf("got %q, want pro-idle. With one request already running on the Ultra, "+
			"Phase 3 should make the idle Pro the better choice.", p.ID)
	}
}

// 100 sequential requests against three idle providers (Ultra/Max/Pro)
// must distribute load — no provider gets >70% of selections. Today:
// Ultra gets ~99% because TPS edge is overwhelming.
func TestAlgorithm_P3_LoadDistributesAcrossIdleProviders(t *testing.T) {
	reg := New(testLogger())
	model := "p3-distribution-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{id: "ultra", decodeTPS: 80, totalMemGB: 512}.register(t, reg, model)
	scenarioProvider{id: "max", decodeTPS: 60, totalMemGB: 128}.register(t, reg, model)
	scenarioProvider{id: "pro", decodeTPS: 20, totalMemGB: 24}.register(t, reg, model)

	counts := map[string]int{}
	const N = 100
	for i := 0; i < N; i++ {
		pr := &PendingRequest{
			RequestID:          fmt.Sprintf("dist-%d", i),
			Model:              model,
			RequestedMaxTokens: 256,
		}
		p := reg.ReserveProvider(model, pr)
		if p == nil {
			t.Fatalf("reservation %d returned nil", i)
		}
		counts[p.ID]++
		// Release immediately so the next iteration sees idle providers.
		// Models the steady-state where requests complete quickly relative
		// to arrival rate.
		p.RemovePending(pr.RequestID)
		reg.SetProviderIdle(p.ID)
	}

	if maxShare := highestShare(counts, N); maxShare > 0.70 {
		t.Fatalf("dominant provider has %.0f%% of selections (counts=%v); want ≤70%% spread. "+
			"Phase 3 (wider near-tie window + stronger queue penalty) is needed.", maxShare*100, counts)
	}
}

// ---------------------------------------------------------------------
// Phase 4 scenarios — load-scaled effective decode TPS
// ---------------------------------------------------------------------

// Big machine running 8 concurrent decodes vs idle small machine. With
// static decodeTPS the big still wins; with load-scaled TPS, the big's
// effective TPS drops to ~80/(1+0.4*8) ≈ 19, comparable to the small,
// and the small (idle) wins on queue depth.
func TestAlgorithm_P4_HighlyBatchedBigLosesToIdleSmall(t *testing.T) {
	reg := New(testLogger())
	model := "p4-batched-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{
		id: "ultra-batched", decodeTPS: 80, totalMemGB: 512, gpuActiveGB: 60,
		pending: 8, backendRun: 8,
	}.register(t, reg, model)
	scenarioProvider{
		id: "pro-idle", decodeTPS: 20, totalMemGB: 24, gpuActiveGB: 1,
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected pro-idle, got nil")
	}
	if p.ID != "pro-idle" {
		t.Fatalf("got %q, want pro-idle. Phase 4 (load-scaled TPS) should make the "+
			"8-batched Ultra effectively as slow as the Pro and lose on queue depth.", p.ID)
	}
}

// Phase 4 isolated: same provider configuration, but the only signal
// the cost function sees is the load-scaled TPS difference. Both
// providers have backendRunning=N but no queued tokens, no health
// penalty, and no idle alternative. The big provider with batch=4
// must lose to the small provider with batch=0 because the static
// TPS edge collapses under the load factor.
func TestAlgorithm_P4_LoadScaledTPSFlipsBatchedBigVsIdleSmall(t *testing.T) {
	reg := New(testLogger())
	model := "p4-load-scaled-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 8}})

	// Big provider: batch=4 in flight (running, no waiting), no
	// pending-token backlog reported, healthy. Static TPS=80, with
	// k=0.4 effective TPS = 80/(1+0.4*4) = 80/2.6 ≈ 30.8.
	scenarioProvider{
		id: "big-batched", decodeTPS: 80, totalMemGB: 128,
		gpuActiveGB: 8, // model resident, low headroom impact
		backendRun:  4,
		slotState:   "running",
	}.register(t, reg, model)

	// Small idle: static TPS=30, no batch scaling applies.
	scenarioProvider{
		id: "small-idle", decodeTPS: 30, totalMemGB: 24,
		gpuActiveGB: 1,
		slotState:   "running",
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected small-idle, got nil")
	}
	if p.ID != "small-idle" {
		t.Fatalf("got %q, want small-idle. Phase 4 load scaling should make "+
			"big-batched effectively slower than small-idle (30.8 vs 30 TPS).", p.ID)
	}
}

// ---------------------------------------------------------------------
// Warm vs cold provider (architectural regression guard)
//
// Providers run one vllm-mlx process per configured model. Multiple
// models serve concurrently; they don't swap. A per-slot warm vs
// idle_shutdown state is the real cost delta.
// ---------------------------------------------------------------------

// A provider whose slot for the requested model is "running" must win
// over a peer whose slot is "idle_shutdown" — the cold one has to
// reload vllm-mlx before it can serve.
func TestAlgorithm_WarmSlotWinsOverIdleShutdown(t *testing.T) {
	reg := New(testLogger())
	model := "warm-vs-cold-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{
		id: "warm", decodeTPS: 80, totalMemGB: 128,
	}.register(t, reg, model)
	scenarioProvider{
		id: "cold", decodeTPS: 80, totalMemGB: 128,
		slotState: "idle_shutdown",
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected warm, got nil")
	}
	if p.ID != "warm" {
		t.Fatalf("got %q, want warm. slotStatePenaltyIdleShutdown must "+
			"keep cold providers at higher cost than running peers.", p.ID)
	}
}

// ---------------------------------------------------------------------
// Regression guards (must stay green across all phases)
// ---------------------------------------------------------------------

// A provider in slot state crashed must never be selected, even if
// it's the fastest hardware in the fleet.
func TestAlgorithm_Regression_CrashedSlotNeverSelected(t *testing.T) {
	reg := New(testLogger())
	model := "regression-crashed-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{
		id: "crashed-fast", decodeTPS: 200, totalMemGB: 512,
		slotState: "crashed",
	}.register(t, reg, model)
	scenarioProvider{
		id: "running-slow", decodeTPS: 30, totalMemGB: 64,
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected running-slow, got nil")
	}
	if p.ID != "running-slow" {
		t.Fatalf("got %q, want running-slow. Crashed slots must never be selected.", p.ID)
	}
}

// A self_signed provider must never be selected when MinTrust=hardware,
// even if it has the best score.
func TestAlgorithm_Regression_TrustLevelGate(t *testing.T) {
	reg := New(testLogger())
	model := "regression-trust-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{
		id: "self-signed-fast", decodeTPS: 200, totalMemGB: 512,
	}.register(t, reg, model)
	pSelf, _ := reg.providers["self-signed-fast"]
	pSelf.mu.Lock()
	pSelf.TrustLevel = TrustSelfSigned
	pSelf.mu.Unlock()

	scenarioProvider{
		id: "hardware-slow", decodeTPS: 30, totalMemGB: 64,
	}.register(t, reg, model)

	p := reserveOne(reg, model, 256)
	if p == nil {
		t.Fatal("expected hardware-slow, got nil")
	}
	if p.ID != "hardware-slow" {
		t.Fatalf("got %q, want hardware-slow. Trust gate must reject self-signed.", p.ID)
	}
}

// ---------------------------------------------------------------------
// Predictive warming scenarios
// ---------------------------------------------------------------------

// testMetricsEmitter captures warming-related metrics for assertions.
type testMetricsEmitter struct {
	mu     sync.Mutex
	counts map[string]int
}

func (m *testMetricsEmitter) Incr(name string, tags []string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.counts == nil {
		m.counts = make(map[string]int)
	}
	key := name + "|" + strings.Join(tags, "|")
	m.counts[key]++
}

func (m *testMetricsEmitter) Gauge(string, float64, []string)     {}
func (m *testMetricsEmitter) Histogram(string, float64, []string) {}

func (m *testMetricsEmitter) count(name string, tags []string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.counts == nil {
		return 0
	}
	key := name + "|" + strings.Join(tags, "|")
	return m.counts[key]
}

// fakeHistoricalSource returns a fixed baseline for demand-forecast tests.
type fakeHistoricalSource struct {
	rps float64
}

func (f *fakeHistoricalSource) HistoricalDemand(context.Context, string, time.Duration) (float64, error) {
	return f.rps, nil
}

// newWarmingRegistry creates a registry with predictive warming enabled.
func newWarmingRegistry(t *testing.T) *Registry {
	t.Helper()
	cfg := DefaultWarmingConfig()
	cfg.Enabled = true
	return NewWithConfig(testLogger(), cfg)
}

// newWarmingRegistryWithHistorical creates a registry with warming enabled and
// a custom historical demand source.
func newWarmingRegistryWithHistorical(t *testing.T, hist HistoricalDemandSource) *Registry {
	t.Helper()
	cfg := DefaultWarmingConfig()
	cfg.Enabled = true
	r := NewWithConfig(testLogger(), cfg)
	if hist != nil {
		f := NewDemandForecaster(hist, cfg)
		r.forecaster = f
		r.warmingPlanner.forecaster = f
	}
	return r
}

// newTestWebSocketConn creates an in-process websocket connection for tests.
// The returned client connection can be passed to Register so SendLoadModel
// succeeds without a real network round-trip.
func newTestWebSocketConn(t *testing.T) *websocket.Conn {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Errorf("accept websocket: %v", err)
			return
		}
		defer conn.Close(websocket.StatusNormalClosure, "")
		for {
			_, _, err := conn.Read(r.Context())
			if err != nil {
				return
			}
		}
	}))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws://"+srv.Listener.Addr().String(), nil)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close(websocket.StatusNormalClosure, "") })
	return conn
}

// addModel advertises an additional model on an already-registered provider.
func addModel(t *testing.T, p *Provider, model string) {
	t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, m := range p.Models {
		if m.ID == model {
			return
		}
	}
	p.Models = append(p.Models, protocol.ModelInfo{
		ID:           model,
		ModelType:    "chat",
		Quantization: "4bit",
	})
}

// pendingLoadForModel returns true if the registry has a pending load_model for
// (provider, model).
func pendingLoadForModel(r *Registry, providerID, model string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.pendingModelLoads[providerID+":"+model]
	return ok
}

// TestAlgorithm_PW_PreQueueWarm verifies that the warming planner sends a
// load_model command as soon as demand appears, before any request actually
// queues. Without predictive warming the request would queue first and only
// then trigger a reactive swap.
func TestAlgorithm_PW_PreQueueWarm(t *testing.T) {
	r := newWarmingRegistry(t)
	metrics := &testMetricsEmitter{}
	r.SetMetricsEmitter(metrics)

	model := "pw-prequeue-model"
	r.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{
		id: "cold", decodeTPS: 30, totalMemGB: 64, gpuActiveGB: 1,
		slotState: "idle_shutdown",
		conn:      newTestWebSocketConn(t),
	}.register(t, r, model)

	// Simulate requests arriving; no request is actually queued.
	for i := 0; i < 10; i++ {
		r.RecordDemand(model)
		time.Sleep(2 * time.Millisecond)
	}

	r.warmingPlanner.tick()

	if !r.providerHasPendingLoad("cold") {
		t.Fatal("expected load_model to be sent pre-queue for demanded model")
	}
	if !pendingLoadForModel(r, "cold", model) {
		t.Fatalf("expected pending load for %q on cold provider", model)
	}
	if metrics.count("warming.load_commands_sent", []string{"model:" + model}) < 1 {
		t.Fatal("expected warming.load_commands_sent metric for the model")
	}
}

// TestAlgorithm_PW_RapidModelShift verifies that the planner warms providers
// for a newly-demanded model even when another model was just warmed. This
// guards against the planner getting stuck on the previous model and ignoring
// a sudden shift in demand.
func TestAlgorithm_PW_RapidModelShift(t *testing.T) {
	r := newWarmingRegistry(t)
	metrics := &testMetricsEmitter{}
	r.SetMetricsEmitter(metrics)

	modelA := "pw-shift-model-a"
	modelB := "pw-shift-model-b"
	r.SetModelCatalog([]CatalogEntry{{ID: modelA}, {ID: modelB}})

	p1 := scenarioProvider{
		id: "p1", decodeTPS: 30, totalMemGB: 128, gpuActiveGB: 1,
		slotState: "idle_shutdown",
		conn:      newTestWebSocketConn(t),
	}.register(t, r, modelA)
	addModel(t, p1, modelB)

	p2 := scenarioProvider{
		id: "p2", decodeTPS: 30, totalMemGB: 128, gpuActiveGB: 1,
		slotState: "idle_shutdown",
		conn:      newTestWebSocketConn(t),
	}.register(t, r, modelA)
	addModel(t, p2, modelB)

	// Demand appears for model A. Only one provider needs to be warm.
	r.RecordQueueDepth(modelA, 1)
	r.warmingPlanner.tick()

	var warmedForA string
	for key := range r.pendingModelLoads {
		pid, m, ok := splitModelLoadKey(key)
		if ok && m == modelA {
			warmedForA = pid
			break
		}
	}
	if warmedForA == "" {
		t.Fatal("expected a pending load_model for model A")
	}

	// Simulate the load completing and model A becoming warm on that provider.
	r.ClearPendingModelLoad(warmedForA, modelA)
	r.MarkModelWarm(warmedForA, modelA)

	// Demand now shifts to model B.
	r.RecordQueueDepth(modelB, 1)
	r.warmingPlanner.tick()

	if !pendingLoadForModel(r, "p1", modelB) && !pendingLoadForModel(r, "p2", modelB) {
		t.Fatal("expected a load_model for model B after demand shifted")
	}
	if metrics.count("warming.load_commands_sent", []string{"model:" + modelB}) < 1 {
		t.Fatal("expected warming.load_commands_sent metric for model B")
	}

	// No extra load for A should be sent: one provider is already warm.
	aLoads := metrics.count("warming.load_commands_sent", []string{"model:" + modelA})
	if aLoads != 1 {
		t.Fatalf("expected exactly 1 load command for model A, got %d", aLoads)
	}
}

// TestAlgorithm_PW_NoWarmWhenUncertain verifies that a purely historical
// baseline (no recent requests, no queued requests) does not trigger eager
// warming. Historical signals alone have low confidence and the planner must
// wait for stronger evidence before spending provider resources.
func TestAlgorithm_PW_NoWarmWhenUncertain(t *testing.T) {
	hist := &fakeHistoricalSource{rps: 0.5}
	r := newWarmingRegistryWithHistorical(t, hist)
	metrics := &testMetricsEmitter{}
	r.SetMetricsEmitter(metrics)

	model := "pw-uncertain-model"
	r.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{
		id: "cold", decodeTPS: 30, totalMemGB: 64, gpuActiveGB: 1,
		slotState: "idle_shutdown",
		conn:      newTestWebSocketConn(t),
	}.register(t, r, model)

	r.warmingPlanner.tick()

	if r.providerHasPendingLoad("cold") {
		t.Fatal("expected no load_model for uncertain historical-only demand")
	}
	if metrics.count("warming.load_commands_sent", []string{"model:" + model}) != 0 {
		t.Fatal("expected no warming.load_commands_sent metric for uncertain demand")
	}

	f := r.Forecast(context.Background(), model)
	if f.Confidence >= 0.5 {
		t.Fatalf("expected low confidence for historical-only signal, got %.2f", f.Confidence)
	}
	if f.RequestsPerSecond <= 0 {
		t.Fatal("expected positive forecasted RPS from historical baseline")
	}
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

// highestShare returns the largest fraction held by any single key.
func highestShare(counts map[string]int, total int) float64 {
	best := 0
	for _, c := range counts {
		if c > best {
			best = c
		}
	}
	return float64(best) / math.Max(1, float64(total))
}
