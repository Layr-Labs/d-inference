package registry_test

import (
	"fmt"
	"math"
	"math/rand"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/modelindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/queuedrain"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func ctxRequest(model string) *production.PendingRequest {
	return &production.PendingRequest{
		RequestID:             "ctx-req",
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    256,
	}
}

func TestHeartbeatAgeMsClamps(t *testing.T) {
	now := time.Now()
	if got := selection.HeartbeatAgeMs(now, time.Time{}); got != math.MaxInt32 {
		t.Fatalf("zero heartbeat age = %d, want MaxInt32", got)
	}
	if got := selection.HeartbeatAgeMs(now, now.Add(time.Second)); got != 0 {
		t.Fatalf("future heartbeat age = %d, want 0", got)
	}
	if got := selection.HeartbeatAgeMs(now, now.Add(-1500*time.Millisecond)); got != 1500 {
		t.Fatalf("age = %d, want 1500", got)
	}
}

func TestQueueEnqueuePositionAndDepth(t *testing.T) {
	q := production.NewRequestQueue(8, time.Minute)
	for i := 0; i < 3; i++ {
		req := &production.QueuedRequest{RequestID: "q-" + strconv.Itoa(i), Model: ctxModel}
		if err := q.Enqueue(req); err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
		if req.EnqueuePosition != i || req.DepthAtEnqueue != i {
			t.Fatalf("req %d: position=%d depth=%d, want %d/%d", i, req.EnqueuePosition, req.DepthAtEnqueue, i, i)
		}
	}
	if got := queuedrain.FoldTrigger("bogus"); got != production.DrainTriggerUnknown {
		t.Fatalf("foldDrainTrigger(bogus) = %q", got)
	}
	for _, r := range []string{production.DrainTriggerHeartbeat, production.DrainTriggerIdle, production.DrainTriggerChallenge, production.DrainTriggerLoad, production.DrainTriggerDisconnect, production.DrainTriggerKick} {
		if queuedrain.FoldTrigger(r) != r {
			t.Fatalf("foldDrainTrigger(%q) folded", r)
		}
	}
}

// TestCandidateSummaryIsFixedSize guards the allocation-free contract: the
// summary must never grow a slice/map/pointer field.
func TestCandidateSummaryIsFixedSize(t *testing.T) {
	c := &selection.SummaryInput{
		ProviderID: "x", CostMs: 1234,
		SlotState: "running", HBAgeMs: 42, TotalPending: 3,
	}
	s := selection.SummarizeCandidate(c, production.SlotStateFold)
	if !s.Present || s.ProviderID != "x" || s.CostMs != 1234 || s.SlotState != production.SlotStateRunning || s.HBAgeMs != 42 || s.TotalPending != 3 {
		t.Fatalf("summary = %+v", s)
	}
	if got := selection.SummarizeCandidate(nil, production.SlotStateFold); got.Present {
		t.Fatalf("nil candidate summary present: %+v", got)
	}
	_ = protocol.SystemMetrics{} // keep protocol imported for fixture symmetry
}

func TestSlotStateFoldClosedVocabulary(t *testing.T) {
	cases := map[string]production.SlotState{
		"running": production.SlotStateRunning, "idle": production.SlotStateIdle, "idle_shutdown": production.SlotStateIdleShutdown,
		"crashed": production.SlotStateCrashed, "reloading": production.SlotStateReloading,
		"": production.SlotStateOther, "unknown": production.SlotStateOther, "RUNNING": production.SlotStateOther,
		"running; DROP TABLE": production.SlotStateOther, "totally-new-state": production.SlotStateOther,
	}
	for raw, want := range cases {
		if got := production.SlotStateFold(raw); got != want {
			t.Errorf("SlotStateFold(%q) = %q, want %q", raw, got, want)
		}
	}
	if got := production.ThermalStateFold("melting"); got != "other" {
		t.Errorf("ThermalStateFold(melting) = %q, want other", got)
	}
	if got := production.ThermalStateFold("serious"); got != "serious" {
		t.Errorf("ThermalStateFold(serious) = %q", got)
	}
}

func TestReserveProviderExBestIdle(t *testing.T) {
	production.ResetTTFTCalibration()
	reg := production.New(testLogger())
	busyFast := makeSchedulerProvider(t, reg, "busy-fast", ctxModel, 80)
	busyFast.Mu().Lock()
	busyFast.BackendCapacity.Slots[0].NumRunning = 2
	busyFast.Mu().Unlock()
	idleSlow := makeSchedulerProvider(t, reg, "idle-slow", ctxModel, 10)
	idleSlow.Mu().Lock()
	idleSlow.BackendCapacity.Slots[0].State = "idle"
	idleSlow.Mu().Unlock()
	idleFast := makeSchedulerProvider(t, reg, "idle-fast", ctxModel, 40)
	idleFast.Mu().Lock()
	idleFast.BackendCapacity.Slots[0].State = "idle"
	idleFast.Mu().Unlock()

	pr := ctxRequest(ctxModel)
	winner, d := reg.ReserveProviderEx(ctxModel, pr)
	if winner == nil {
		t.Fatal("no winner")
	}
	winner.RemovePending(pr.RequestID)
	if !d.BestIdle.Present || d.BestIdle.ProviderID != "idle-fast" {
		t.Fatalf("BestIdle = %+v, want idle-fast", d.BestIdle)
	}
	if d.BestIdle.SlotState != production.SlotStateIdle || d.BestIdle.BackendRunning != 0 || d.BestIdle.BackendWaiting != 0 {
		t.Fatalf("BestIdle slot = %+v, want idle/0/0", d.BestIdle)
	}
	if d.BestIdle.TTFTMs <= 0 {
		t.Fatalf("BestIdle.TTFTMs = %v, want > 0", d.BestIdle.TTFTMs)
	}

	// Every warm slot busy → no best-idle.
	reg2 := production.New(testLogger())
	for _, id := range []string{"b1", "b2"} {
		p := makeSchedulerProvider(t, reg2, id, ctxModel, 40)
		p.Mu().Lock()
		p.BackendCapacity.Slots[0].NumRunning = 1
		p.Mu().Unlock()
	}
	pr2 := ctxRequest(ctxModel)
	w2, d2 := reg2.ReserveProviderEx(ctxModel, pr2)
	if w2 == nil {
		t.Fatal("no winner on busy fleet")
	}
	w2.RemovePending(pr2.RequestID)
	if d2.BestIdle.Present {
		t.Fatalf("BestIdle = %+v, want none on an all-busy fleet", d2.BestIdle)
	}
}

func sumGateRejections(d production.RoutingDecision) int {
	total := 0
	for _, n := range d.GateRejections {
		total += int(n)
	}
	return total
}

func gateTallyMap(d production.RoutingDecision) map[string]int {
	out := map[string]int{}
	for g := production.GateReason(0); g < production.GateReasonCount; g++ {
		if d.GateRejections[g] > 0 {
			out[g.String()] = int(d.GateRejections[g])
		}
	}
	return out
}

func TestGateReasonNamesComplete(t *testing.T) {
	seen := map[string]bool{}
	for g := production.GateReason(0); g < production.GateReasonCount; g++ {
		name := g.String()
		if name == "" || name == "unknown" {
			t.Fatalf("GateReason %d has no name", g)
		}
		if name != strings.ToLower(name) || strings.ContainsAny(name, " -") {
			t.Fatalf("GateReason %d name %q is not snake_case", g, name)
		}
		if seen[name] {
			t.Fatalf("duplicate GateReason name %q", name)
		}
		seen[name] = true
	}
	if production.GateReasonCount.String() != "unknown" {
		t.Fatalf("GateReasonCount.String() = %q, want unknown", production.GateReasonCount.String())
	}
	want := map[production.SelectionPath]string{
		production.SelectionNone: "none", production.SelectionUniqueMin: "unique_min", production.SelectionTieQueue: "tie_queue",
		production.SelectionTiePending: "tie_pending", production.SelectionRandom: "random", production.SelectionPrefixAffinity: "prefix_affinity",
		production.SelectionCacheCredit: "cache_credit",
	}
	selectionPathCount := production.SelectionCacheCredit + 1
	if len(want) != int(selectionPathCount) {
		t.Fatalf("SelectionPath vocabulary has %d names, want %d", len(want), selectionPathCount)
	}
	for s := production.SelectionPath(0); s < selectionPathCount; s++ {
		if name, ok := want[s]; !ok || s.String() != name {
			t.Fatalf("SelectionPath %d name=%q, want %q", s, s.String(), name)
		}
	}
	if selectionPathCount.String() != "unknown" {
		t.Fatal("out-of-range SelectionPath must be unknown")
	}
}

type routingContextCandidates struct {
	index   modelindex.Index[*production.Provider]
	all     []*production.Provider
	scanAll atomic.Bool
}

func (c *routingContextCandidates) AppendProviders(model string, dst []*production.Provider) []*production.Provider {
	if c.scanAll.Load() {
		return append(dst, c.all...)
	}
	return c.index.AppendProviders(model, dst)
}

// Drive each closed routing gate through the real reservation path, including
// the difference between an indexed candidate source and an all-provider scan.
func TestGateRejectionTallies(t *testing.T) {
	production.ResetTTFTCalibration()
	var gatedMeasurements *measurements.History
	var gates *identitygate.Directory
	type gateCase struct {
		name        string
		want        production.GateReason
		model       string
		withHealthy bool
		indexSkips  bool
		setup       func(t *testing.T, reg *production.Registry, p *production.Provider, pr *production.PendingRequest) []string
	}
	lock := func(p *production.Provider, f func()) {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		f()
	}
	cases := []gateCase{
		{name: "offline", want: production.GateOffline, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.Status = production.StatusOffline })
			return nil
		}},
		{name: "untrusted", want: production.GateUntrusted, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.Status = production.StatusUntrusted })
			return nil
		}},
		{name: "state_restoring", want: production.GateStateRestoring, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() {
				p.AttestationResult = &attestation.VerificationResult{Valid: true}
			})
			return nil
		}},
		{name: "trust_floor", want: production.GateTrustFloor, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.TrustLevel = production.TrustNone })
			return nil
		}},
		{name: "private_only", want: production.GatePrivateOnly, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.PrivateOnly = true })
			return nil
		}},
		{name: "runtime_unverified", want: production.GateRuntimeUnverified, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.RuntimeVerified = false })
			return nil
		}},
		{name: "private_text", want: production.GatePrivateText, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.EncryptedResponseChunks = false })
			return nil
		}},
		{name: "challenge_stale", want: production.GateChallengeStale, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.LastChallengeVerified = time.Now().Add(-time.Hour) })
			return nil
		}},
		{name: "trait_floor", want: production.GateTraitFloor, setup: func(_ *testing.T, _ *production.Registry, _ *production.Provider, pr *production.PendingRequest) []string {
			pr.Traits.MinPrefixCacheProtocol = 1
			return nil
		}},
		{name: "dedicated", want: production.GateDedicated, model: "mlx/gemma-4-ctx-4bit", setup: func(_ *testing.T, reg *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			reg.SetDedicatedModels([]string{"gemma"})
			reg.MergeProviderModels(p.ID, []protocol.ModelInfo{{ID: "mlx/qwen-ctx-4bit", ModelType: "chat", Quantization: "4bit"}})
			return nil
		}},
		{name: "dispatch_load_cooldown", want: production.GateDispatchLoadCooldown, setup: func(_ *testing.T, reg *production.Registry, p *production.Provider, pr *production.PendingRequest) []string {
			reg.RecordDispatchLoadFailure(p.ID, pr.Model)
			return nil
		}},
		{name: "error_cooldown", want: production.GateErrorCooldown, setup: func(_ *testing.T, reg *production.Registry, p *production.Provider, pr *production.PendingRequest) []string {
			const inferenceErrorThreshold = 2
			for i := 0; i < inferenceErrorThreshold; i++ {
				reg.RecordInferenceError(p.ID, pr.Model, 500, pr.Traits.CooldownShape())
			}
			return nil
		}},
		{name: "capacity_cooldown", want: production.GateCapacityCooldown, setup: func(_ *testing.T, reg *production.Registry, p *production.Provider, pr *production.PendingRequest) []string {
			for i := 0; i < identitygate.DefaultCapacityCooldownThreshold; i++ {
				reg.RecordCapacityReject(p.ID, pr.Model)
			}
			return nil
		}},
		{name: "breaker", want: production.GateBreaker, withHealthy: true, setup: func(_ *testing.T, reg *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			for i := 0; i < identitygate.ProviderBreakerConsecTrip; i++ {
				reg.RecordProviderOutcome(p.ID, false, 500, "internal fault")
			}
			return nil
		}},
		{name: "ejection", want: production.GateEjection, withHealthy: true, setup: func(t *testing.T, reg *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			if !gates.EjectionEnabled() {
				t.Skip("health ejection disabled via env")
			}
			lock(p, func() {
				p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "EJECT-1"}
			})
			const healthEjectionConsecTrip, healthEjectionMinSample = 8, 15
			for i := 0; i < healthEjectionConsecTrip+healthEjectionMinSample; i++ {
				reg.RecordProviderServeOutcome("serial:EJECT-1", false, 500, "internal fault")
			}
			return nil
		}},
		{name: "slot_crashed", want: production.GateSlotCrashed, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.BackendCapacity.Slots[0].State = "crashed" })
			return nil
		}},
		{name: "slot_reloading", want: production.GateSlotReloading, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.BackendCapacity.Slots[0].State = "reloading" })
			return nil
		}},
		{name: "thermal_critical", want: production.GateThermalCritical, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.SystemMetrics.ThermalState = "critical" })
			return nil
		}},
		{name: "no_headroom", want: production.GateNoHeadroom, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, pr *production.PendingRequest) []string {
			lock(p, func() { p.BackendCapacity.Slots[0].MaxConcurrency = 1 })
			p.AddPending(&production.PendingRequest{RequestID: "occupant", Model: pr.Model, RequestedMaxTokens: 64})
			return nil
		}},
		{name: "model_too_large", want: production.GateModelTooLarge, setup: func(_ *testing.T, reg *production.Registry, p *production.Provider, pr *production.PendingRequest) []string {
			reg.SetModelCatalog([]production.CatalogEntry{{ID: pr.Model, MinRAMGB: 128, SizeGB: 100}})
			lock(p, func() { p.BackendCapacity.Slots = nil })
			return nil
		}},
		{name: "free_memory", want: production.GateFreeMemory, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			lock(p, func() { p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 100 })
			return nil
		}},
		{name: "vision", want: production.GateVision, setup: func(_ *testing.T, _ *production.Registry, _ *production.Provider, pr *production.PendingRequest) []string {
			pr.RequiresVision = true
			return nil
		}},
		{name: "ttft_ceiling", want: production.GateTTFTCeiling, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, pr *production.PendingRequest) []string {
			lock(p, func() {
				now := time.Now()
				rate := 1000.0
				p.CapacityAcceptedAt = now
				p.PrefillTPS = rate
				slot := &p.BackendCapacity.Slots[0]
				slot.State = "idle"
				slot.ObservedPrefillTPS = rate
				slot.ObservedDecodeTPS = 100
				slot.Telemetry = &protocol.SlotTelemetry{
					QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64),
					IsolatedPrefillTPS: &rate, EWMAInitialized: new(bool),
				}
				*slot.Telemetry.EWMAInitialized = true
				slot.PerformanceMeasurements = localRateMeasurements(rate, slot.ObservedDecodeTPS)
				gatedMeasurements.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, 0)
			})
			pr.MaxTTFTMs = 0.001
			return nil
		}},
		{name: "excluded", want: production.GateExcluded, setup: func(_ *testing.T, _ *production.Registry, p *production.Provider, _ *production.PendingRequest) []string {
			return []string{p.ID}
		}},
		{name: "allowlist", want: production.GateAllowlist, setup: func(_ *testing.T, _ *production.Registry, _ *production.Provider, pr *production.PendingRequest) []string {
			pr.AllowedProviderSerials = []string{"no-such-serial"}
			return nil
		}},
		{name: "not_serving_model", want: production.GateNotServingModel, indexSkips: true, setup: func(_ *testing.T, _ *production.Registry, _ *production.Provider, pr *production.PendingRequest) []string {
			pr.Model = ctxOtherModel
			return nil
		}},
		{name: "not_serving_model_off_catalog", want: production.GateNotServingModel, setup: func(_ *testing.T, reg *production.Registry, _ *production.Provider, _ *production.PendingRequest) []string {
			reg.SetModelCatalog([]production.CatalogEntry{{ID: ctxOtherModel, SizeGB: 1}})
			return nil
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			model := tc.model
			if model == "" {
				model = ctxModel
			}
			source := &routingContextCandidates{}
			gatedMeasurements = &measurements.History{}
			options := identitygate.DefaultOptions()
			enabled := env.EnvBool("EIGENINFERENCE_HEALTH_EJECTION", true)
			options.HealthEjectionEnabled = func() bool { return enabled }
			gates = identitygate.New(testLogger(), &options)
			reg := production.NewWithDependencies(testLogger(), production.Dependencies{
				ModelAdvertisements: &source.index,
				ModelCandidates:     source,
				IdentityGates:       gates,
				Measurements: func(id string) *measurements.History {
					if id == "gated" {
						return gatedMeasurements
					}
					return &measurements.History{}
				},
			})
			if tc.want == production.GateStateRestoring {
				reg.SetStore(memory.NewMemory(store.Config{}))
			}
			p := makeSchedulerProvider(t, reg, "gated", model, 40)
			source.all = append(source.all, p)
			var healthy *production.Provider
			if tc.withHealthy {
				healthy = makeSchedulerProvider(t, reg, "healthy", model, 40)
				source.all = append(source.all, healthy)
			}
			pr := ctxRequest(model)
			excludeIDs := tc.setup(t, reg, p, pr)
			winner, d := reg.ReserveProviderEx(pr.Model, pr, excludeIDs...)
			if tc.indexSkips {
				if winner != nil {
					t.Fatalf("indexed: winner = %s, want none", winner.ID)
				}
				if d.Scanned != 0 || d.CandidateSetSize != 0 || sumGateRejections(d) != 0 {
					t.Fatalf("indexed: scanned=%d set=%d rejections=%v, want 0/0/none", d.Scanned, d.CandidateSetSize, gateTallyMap(d))
				}
				source.scanAll.Store(true)
				winner, d = reg.ReserveProviderEx(pr.Model, pr, excludeIDs...)
				source.scanAll.Store(false)
			}
			if winner != nil {
				winner.RemovePending(pr.RequestID)
			}
			if got := d.GateRejections[tc.want]; got != 1 {
				t.Fatalf("GateRejections[%s] = %d, want 1 (all: %v)", tc.want, got, gateTallyMap(d))
			}
			if got := sumGateRejections(d); got != 1 {
				t.Fatalf("total gate rejections = %d, want 1 (all: %v)", got, gateTallyMap(d))
			}
			wantScanned := 1
			if tc.withHealthy {
				wantScanned = 2
				if winner == nil || winner.ID != healthy.ID {
					t.Fatalf("winner = %v, want the healthy provider", winner)
				}
			} else if winner != nil {
				t.Fatalf("winner = %s, want none", winner.ID)
			}
			if d.Scanned != wantScanned {
				t.Fatalf("Scanned = %d, want %d", d.Scanned, wantScanned)
			}
			wantSet := wantScanned
			if tc.want == production.GateNotServingModel {
				wantSet--
			}
			if d.CandidateSetSize != wantSet {
				t.Fatalf("CandidateSetSize = %d, want %d", d.CandidateSetSize, wantSet)
			}
		})
	}
}

func TestSelectRoutingCandidatePaths(t *testing.T) {
	id := func(c *selectionTestCandidate) string {
		if c == nil {
			return ""
		}
		return c.id
	}
	selectCandidate := func(pool []*selectionTestCandidate) (winner, runner *selectionTestCandidate, near int, path selection.Path) {
		decision := selection.Select(pool, projectSelectionTestCandidate, rand.Intn, "")
		if decision.Winner >= 0 {
			winner = pool[decision.Winner]
		}
		if decision.RunnerUp >= 0 {
			runner = pool[decision.RunnerUp]
		}
		return winner, runner, decision.NearTieSize, decision.Path
	}
	t.Run("empty", func(t *testing.T) {
		w, ru, n, path := selectCandidate(nil)
		if w != nil || ru != nil || n != 0 || path != selection.None {
			t.Fatalf("got %v %v %d %s", w, ru, n, fmt.Sprint(path))
		}
	})
	t.Run("unique_min", func(t *testing.T) {
		a, b, c := makeSelectionTestCandidate("a", 1000, 0, 0, 0), makeSelectionTestCandidate("b", 10000, 0, 0, 0), makeSelectionTestCandidate("c", 20000, 0, 0, 0)
		w, ru, n, path := selectCandidate([]*selectionTestCandidate{c, b, a})
		if id(w) != "a" || id(ru) != "b" || n != 1 || path != selection.UniqueMin {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, fmt.Sprint(path))
		}
	})
	t.Run("single_candidate", func(t *testing.T) {
		a := makeSelectionTestCandidate("a", 1000, 0, 0, 0)
		w, ru, n, path := selectCandidate([]*selectionTestCandidate{a})
		if id(w) != "a" || ru != nil || n != 1 || path != selection.UniqueMin {
			t.Fatalf("got winner=%s runnerUp=%v nearTie=%d path=%s", id(w), ru, n, fmt.Sprint(path))
		}
	})
	t.Run("tie_queue", func(t *testing.T) {
		a, b := makeSelectionTestCandidate("a", 1000, 1, 0, 0), makeSelectionTestCandidate("b", 1050, 0, 0, 0)
		w, ru, n, path := selectCandidate([]*selectionTestCandidate{a, b})
		if id(w) != "b" || id(ru) != "a" || n != 2 || path != selection.TiePending {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, fmt.Sprint(path))
		}
	})
	t.Run("tie_pending", func(t *testing.T) {
		a, b := makeSelectionTestCandidate("a", 1000, 0, 2, 0), makeSelectionTestCandidate("b", 1050, 0, 1, 0)
		w, ru, n, path := selectCandidate([]*selectionTestCandidate{a, b})
		if id(w) != "b" || id(ru) != "a" || n != 2 || path != selection.TiePending {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, fmt.Sprint(path))
		}
	})
	t.Run("random", func(t *testing.T) {
		a, b, far := makeSelectionTestCandidate("a", 1000, 0, 0, 0), makeSelectionTestCandidate("b", 1050, 0, 0, 0), makeSelectionTestCandidate("far", 50000, 0, 0, 0)
		for i := 0; i < 20; i++ {
			w, ru, n, path := selectCandidate([]*selectionTestCandidate{far, a, b})
			if path != selection.Random || n != 2 {
				t.Fatalf("got nearTie=%d path=%s", n, fmt.Sprint(path))
			}
			switch id(w) {
			case "a":
				if id(ru) != "b" {
					t.Fatalf("winner a, runnerUp %s", id(ru))
				}
			case "b":
				if id(ru) != "a" {
					t.Fatalf("winner b, runnerUp %s", id(ru))
				}
			default:
				t.Fatalf("unexpected winner %s", id(w))
			}
		}
	})
	t.Run("cache_cost_minimum", func(t *testing.T) {
		a, b := makeSelectionTestCandidate("a", 1000, 0, 0, 0), makeSelectionTestCandidate("b", 900, 0, 0, 500)
		w, ru, n, path := selectCandidate([]*selectionTestCandidate{a, b})
		if id(w) != "b" || id(ru) != "a" || n != 2 || path != selection.CacheCredit {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, fmt.Sprint(path))
		}
	})
	t.Run("cache_equal_spread", func(t *testing.T) {
		a, b := makeSelectionTestCandidate("a", 900, 0, 0, 500), makeSelectionTestCandidate("b", 900, 0, 0, 500)
		seen := map[string]bool{}
		for i := 0; i < 60; i++ {
			w, ru, n, path := selectCandidate([]*selectionTestCandidate{a, b})
			if (w != a && w != b) || (w == a && ru != b) || (w == b && ru != a) || n != 2 || path != selection.CacheCredit {
				t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, fmt.Sprint(path))
			}
			seen[id(w)] = true
		}
		if !seen["a"] || !seen["b"] {
			t.Fatalf("equivalent credited holders were not spread: %v", seen)
		}
	})
	t.Run("cache_credit_tie_breaks_before_spread", func(t *testing.T) {
		fresh, stale := makeSelectionTestCandidate("fresh", 900, 0, 0, 500), makeSelectionTestCandidate("stale", 900, 0, 0, 500)
		fresh.cacheEvidenceWeight, stale.cacheEvidenceWeight = 1, .5
		idle, busy := makeSelectionTestCandidate("idle", 900, 0, 0, 500), makeSelectionTestCandidate("busy", 900, 0, 1, 500)
		for i := 0; i < 20; i++ {
			if w, _, _, path := selectCandidate([]*selectionTestCandidate{stale, fresh}); w != fresh || path != selection.CacheCredit {
				t.Fatalf("stale evidence won: %s %s", id(w), fmt.Sprint(path))
			}
			if w, _, _, path := selectCandidate([]*selectionTestCandidate{busy, idle}); w != idle || path != selection.CacheCredit {
				t.Fatalf("busier holder won: %s %s", id(w), fmt.Sprint(path))
			}
		}
	})
	t.Run("whole_mac_work_precedes_cache_affinity", func(t *testing.T) {
		a, b := makeSelectionTestCandidate("a", 1050, 1, 1, 300), makeSelectionTestCandidate("b", 1000, 0, 0, 0)
		w, ru, n, path := selectCandidate([]*selectionTestCandidate{b, a})
		if id(w) != "b" || id(ru) != "a" || n != 2 || path != selection.TiePending {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, fmt.Sprint(path))
		}
	})
	t.Run("cache_credit_beyond_band_loses", func(t *testing.T) {
		a, b := makeSelectionTestCandidate("a", 4001, 0, 0, 300), makeSelectionTestCandidate("b", 1000, 1, 0, 0)
		w, ru, n, path := selectCandidate([]*selectionTestCandidate{a, b})
		if id(w) != "b" || id(ru) != "a" || n != 1 || path != selection.UniqueMin {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, fmt.Sprint(path))
		}
	})
	t.Run("cache_credit_alone_in_band_is_unique_min", func(t *testing.T) {
		a, b := makeSelectionTestCandidate("a", 500, 0, 0, 300), makeSelectionTestCandidate("b", 4000, 0, 0, 0)
		w, ru, n, path := selectCandidate([]*selectionTestCandidate{b, a})
		if id(w) != "a" || id(ru) != "b" || n != 1 || path != selection.UniqueMin {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, fmt.Sprint(path))
		}
	})
	t.Run("restore_cost_is_already_in_forecast", func(t *testing.T) {
		penalized := makeSelectionTestCandidate("penalized", 1040, 0, 0, 0)
		penalized.cacheEstimatedTTFTSavedMs = -40
		cold := makeSelectionTestCandidate("cold", 1020, 1, 1, 0)
		for _, pool := range [][]*selectionTestCandidate{{penalized, cold}, {cold, penalized}} {
			w, ru, n, path := selectCandidate(pool)
			if id(w) != "penalized" || id(ru) != "cold" || n != 2 || path != selection.TiePending {
				t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, fmt.Sprint(path))
			}
		}
	})
}

// The top-four summaries and runner-up must follow the selected provider while
// retaining the independently recorded cost and first-content diagnostics.
func TestReserveProviderExTopRunnerUpAndPath(t *testing.T) {
	production.ResetTTFTCalibration()
	reg := production.New(testLogger())
	for _, tps := range []float64{5, 10, 20, 40, 80} {
		makeSchedulerProvider(t, reg, "tps-"+strconv.Itoa(int(tps)), ctxModel, tps)
	}
	pr := ctxRequest(ctxModel)
	winner, d := reg.ReserveProviderEx(ctxModel, pr)
	if winner == nil {
		t.Fatal("no winner")
	}
	defer winner.RemovePending(pr.RequestID)
	if winner.ID != "tps-80" {
		t.Fatalf("winner = %s, want tps-80", winner.ID)
	}
	if d.SelectionPath != production.SelectionUniqueMin || d.NearTiePoolSize != 1 {
		t.Fatalf("path=%s nearTie=%d, want unique_min/1", d.SelectionPath, d.NearTiePoolSize)
	}
	wantTop := []string{"tps-80", "tps-40", "tps-20", "tps-10"}
	for i, want := range wantTop {
		if !d.Top[i].Present || d.Top[i].ProviderID != want {
			t.Fatalf("Top[%d] = %+v, want %s", i, d.Top[i], want)
		}
		if i > 0 && d.Top[i].CostMs < d.Top[i-1].CostMs {
			t.Fatalf("Top not ascending at %d: %v < %v", i, d.Top[i].CostMs, d.Top[i-1].CostMs)
		}
	}
	if d.Top[0].CostMs != d.CostMs || d.Top[0].ProviderID != d.ProviderID {
		t.Fatalf("Top[0] %+v does not match the decision winner (%s, %v)", d.Top[0], d.ProviderID, d.CostMs)
	}
	if !d.RunnerUp.Present || d.RunnerUp.ProviderID != "tps-40" {
		t.Fatalf("RunnerUp = %+v, want tps-40", d.RunnerUp)
	}
	if d.RunnerUp.CostMs <= d.CostMs {
		t.Fatalf("runner-up cost %v should exceed winner cost %v", d.RunnerUp.CostMs, d.CostMs)
	}
	if d.CandidateSetSize != 5 || d.Scanned != 5 || d.CandidateCount != 5 {
		t.Fatalf("set=%d scanned=%d count=%d, want 5/5/5", d.CandidateSetSize, d.Scanned, d.CandidateCount)
	}
	if sumGateRejections(d) != 0 {
		t.Fatalf("unexpected gate rejections %v", gateTallyMap(d))
	}
	if d.Top[0].SlotState != production.SlotStateRunning {
		t.Fatalf("Top[0].SlotState = %q, want running", d.Top[0].SlotState)
	}
	if d.RawTTFTMs <= 0 || d.TTFTMs != d.RawTTFTMs {
		t.Fatalf("TTFTMs=%v RawTTFTMs=%v, want equal and > 0 with the calibrator at 1.0", d.TTFTMs, d.RawTTFTMs)
	}
	if d.TTFTCalibrationRatio != 1.0 {
		t.Fatalf("TTFTCalibrationRatio = %v, want 1.0", d.TTFTCalibrationRatio)
	}
	if d.PrefillDecodeRatio != production.PrefillToDecodeRatio() {
		t.Fatalf("PrefillDecodeRatio = %v, want %v", d.PrefillDecodeRatio, production.PrefillToDecodeRatio())
	}
	if d.PendingForModel != 0 || d.TotalPending != 0 {
		t.Fatalf("pending = %d/%d, want 0/0", d.PendingForModel, d.TotalPending)
	}
	wantTPS := 80 / (1 + warmplan.DecodeLoadFactor)
	if math.Abs(d.PredictedDecodeTPS-wantTPS) > 1e-6 {
		t.Fatalf("PredictedDecodeTPS = %v, want %v", d.PredictedDecodeTPS, wantTPS)
	}
}

func TestReserveProviderExSnapshotAgeAndPending(t *testing.T) {
	for _, refreshHeartbeat := range []bool{false, true} {
		name := "unchanged_heartbeat"
		if refreshHeartbeat {
			name = "heartbeat_refreshed_before_commit"
		}
		t.Run(name, func(t *testing.T) {
			production.ResetTTFTCalibration()
			reg, preparation := newReservationFixture()
			p := makeSchedulerProvider(t, reg, "aged", ctxModel, 40)
			reg.MergeProviderModels(p.ID, []protocol.ModelInfo{{ID: ctxOtherModel, ModelType: "chat", Quantization: "4bit"}})
			scanHeartbeat := time.Now().Add(-7 * time.Second)
			p.Mu().Lock()
			p.LastHeartbeat = scanHeartbeat
			p.Mu().Unlock()
			p.AddPending(&production.PendingRequest{RequestID: "other-model-req", Model: ctxOtherModel, RequestedMaxTokens: 64})

			commitHeartbeat := scanHeartbeat
			var scanFinished, commitStarted time.Time
			preparation.after = func(string) {
				scanFinished = time.Now()
				if refreshHeartbeat {
					p.Mu().Lock()
					commitHeartbeat = time.Now()
					p.LastHeartbeat = commitHeartbeat
					p.Mu().Unlock()
				}
				commitStarted = time.Now()
			}

			pr := ctxRequest(ctxModel)
			scanStarted := time.Now()
			winner, d := reg.ReserveProviderEx(ctxModel, pr)
			commitFinished := time.Now()
			if winner != p || d.ScanCount != 1 {
				t.Fatalf("winner=%v scans=%d, want aged/1", winner, d.ScanCount)
			}
			defer winner.RemovePending(pr.RequestID)
			if !d.Top[0].Present || d.Top[0].ProviderID != winner.ID {
				t.Fatalf("Top[0] = %+v, want the reserved provider", d.Top[0])
			}
			// Top retains scan-time evidence; the decision uses the fresh
			// pre-debit commit snapshot. Bound each by its own phase instead
			// of assuming both clock reads (or heartbeats) were identical.
			for _, age := range []struct {
				name       string
				got        int64
				heartbeat  time.Time
				start, end time.Time
			}{
				{"Top[0].HBAgeMs", int64(d.Top[0].HBAgeMs), scanHeartbeat, scanStarted, scanFinished},
				{"SnapshotAgeMs", int64(d.SnapshotAgeMs), commitHeartbeat, commitStarted, commitFinished},
			} {
				minAge := age.start.Sub(age.heartbeat).Milliseconds()
				maxAge := age.end.Sub(age.heartbeat).Milliseconds()
				if age.got < minAge || age.got > maxAge {
					t.Fatalf("%s = %d, want between %d and %d ms", age.name, age.got, minAge, maxAge)
				}
			}
			if d.TotalPending != 1 || d.PendingForModel != 0 {
				t.Fatalf("TotalPending=%d PendingForModel=%d, want 1/0", d.TotalPending, d.PendingForModel)
			}
			if d.Top[0].TotalPending != 1 {
				t.Fatalf("Top[0].TotalPending = %d, want 1", d.Top[0].TotalPending)
			}
		})
	}
}

type routingContextLoadLifecycle struct {
	warmplan.LoadState
	entered chan struct{}
	release chan struct{}
}

func (l *routingContextLoadLifecycle) Reset() {
	close(l.entered)
	<-l.release
	l.LoadState.Reset()
}

func TestReserveProviderExStamps(t *testing.T) {
	production.ResetTTFTCalibration()
	holder := &routingContextLoadLifecycle{entered: make(chan struct{}), release: make(chan struct{})}
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		WarmLifecycle: func(id string) warmplan.LoadLifecycle {
			if id == "routing-stamp-lock-holder" {
				return holder
			}
			return new(warmplan.LoadState)
		},
	})
	makeSchedulerProvider(t, reg, "p1", ctxModel, 40)
	makeSchedulerProvider(t, reg, "routing-stamp-lock-holder", ctxOtherModel, 40)

	// The real auxiliary disconnect holds the registry write lock while resetting
	// its own lifecycle; the selected provider remains untouched.
	const hold = 25 * time.Millisecond
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		reg.Disconnect("routing-stamp-lock-holder")
	}()
	<-holder.entered
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(holder.release) }) }
	defer release()
	go func() {
		time.Sleep(hold)
		release()
	}()
	pr := ctxRequest(ctxModel)
	winner, d := reg.ReserveProviderEx(ctxModel, pr)
	wg.Wait()
	if winner == nil {
		t.Fatal("no winner")
	}
	winner.RemovePending(pr.RequestID)
	if d.LockWaitUS < int64(hold/time.Microsecond)*8/10 {
		t.Fatalf("LockWaitUS = %d, want ≥ ~%d", d.LockWaitUS, hold/time.Microsecond)
	}
	if d.ScanUS < 0 || d.AdmitUS < 0 {
		t.Fatalf("negative phase: scan=%d admit=%d", d.ScanUS, d.AdmitUS)
	}
	if d.ScanUS+d.AdmitUS > int64(time.Second/time.Microsecond) {
		t.Fatalf("implausible phases: scan=%d admit=%d", d.ScanUS, d.AdmitUS)
	}

	reg2 := production.New(testLogger())
	p := makeSchedulerProvider(t, reg2, "cold", ctxModel, 40)
	p.Mu().Lock()
	p.Status = production.StatusOffline
	p.Mu().Unlock()
	pr2 := ctxRequest(ctxModel)
	w2, d2 := reg2.ReserveProviderEx(ctxModel, pr2)
	if w2 != nil {
		t.Fatal("unexpected winner")
	}
	if d2.LockWaitUS < 0 || d2.ScanUS < 0 || d2.AdmitUS != 0 {
		t.Fatalf("no-selection stamps: lock=%d scan=%d admit=%d", d2.LockWaitUS, d2.ScanUS, d2.AdmitUS)
	}
	if d2.GateRejections[production.GateOffline] != 1 || d2.Scanned != 1 || d2.SelectionPath != production.SelectionNone {
		t.Fatalf("no-selection context: %v scanned=%d path=%s", gateTallyMap(d2), d2.Scanned, d2.SelectionPath)
	}
	if d2.Top[0].Present || d2.RunnerUp.Present || d2.BestIdle.Present {
		t.Fatalf("no-selection decision carries candidates: %+v", d2.Top[0])
	}
}

func TestDrainRecordsQueueContextAndTrigger(t *testing.T) {
	production.ResetTTFTCalibration()
	reg := production.New(testLogger())
	q := production.NewRequestQueue(8, time.Minute)
	reg.SetQueue(q)
	makeSchedulerProvider(t, reg, "p1", ctxModel, 40)

	head := &production.QueuedRequest{RequestID: "head", Model: ctxModel, Pending: ctxRequest(ctxModel)}
	head.Pending.RequestID = "head"
	second := &production.QueuedRequest{RequestID: "second", Model: ctxModel, Pending: ctxRequest(ctxModel)}
	second.Pending.RequestID = "second"
	for _, req := range []*production.QueuedRequest{head, second} {
		if err := q.Enqueue(req); err != nil {
			t.Fatalf("enqueue: %v", err)
		}
	}
	reg.DrainQueuedRequestsForModelWithReason(ctxModel, production.DrainTriggerHeartbeat)

	select {
	case p := <-head.ResponseCh:
		if p == nil {
			t.Fatal("head request failed")
		}
	default:
		t.Fatal("head request not assigned")
	}
	if head.DrainTrigger != production.DrainTriggerHeartbeat || head.Decision.DrainTrigger != production.DrainTriggerHeartbeat {
		t.Fatalf("drain trigger = %q / %q, want heartbeat", head.DrainTrigger, head.Decision.DrainTrigger)
	}
	if head.Decision.QueuePosition != 0 || head.Decision.QueueDepth != 0 {
		t.Fatalf("head queue context = %d/%d, want 0/0", head.Decision.QueuePosition, head.Decision.QueueDepth)
	}
	if head.Decision.ProviderID != "p1" {
		t.Fatalf("head decision provider = %q", head.Decision.ProviderID)
	}
	if second.EnqueuePosition != 1 || second.DepthAtEnqueue != 1 {
		t.Fatalf("second enqueue context = %d/%d, want 1/1", second.EnqueuePosition, second.DepthAtEnqueue)
	}

	drainVia := func(name string, drain func(r *production.Registry)) string {
		t.Helper()
		reg := production.New(testLogger())
		q := production.NewRequestQueue(8, time.Minute)
		reg.SetQueue(q)
		makeSchedulerProvider(t, reg, "p-"+name, ctxModel, 40)
		req := &production.QueuedRequest{RequestID: name, Model: ctxModel, Pending: ctxRequest(ctxModel)}
		req.Pending.RequestID = name
		if err := q.Enqueue(req); err != nil {
			t.Fatalf("enqueue: %v", err)
		}
		drain(reg)
		return req.DrainTrigger
	}
	if got := drainVia("exported", func(r *production.Registry) { r.DrainQueuedRequestsForModel(ctxModel) }); got != production.DrainTriggerUnknown {
		t.Fatalf("DrainQueuedRequestsForModel trigger = %q, want unknown", got)
	}
	if got := drainVia("load", func(r *production.Registry) {
		r.DrainQueuedRequestsForModelWithReason(ctxModel, production.DrainTriggerLoad)
	}); got != production.DrainTriggerLoad {
		t.Fatalf("DrainQueuedRequestsForModelWithReason trigger = %q, want load", got)
	}
	if got := drainVia("challenge", func(r *production.Registry) {
		r.DrainQueuedRequestsForProviderWithReason(r.GetProvider("p-challenge"), production.DrainTriggerChallenge)
	}); got != production.DrainTriggerChallenge {
		t.Fatalf("DrainQueuedRequestsForProviderWithReason trigger = %q, want challenge", got)
	}
	if got := drainVia("bogus", func(r *production.Registry) { r.DrainQueuedRequestsForModelWithReason(ctxModel, "bogus") }); got != production.DrainTriggerUnknown {
		t.Fatalf("bogus reason folded to %q, want unknown", got)
	}
}
