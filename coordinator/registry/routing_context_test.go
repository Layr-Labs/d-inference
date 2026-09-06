package registry

import (
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// routing_context_test.go — system-profiler routing context on RoutingDecision
// (gate-reason tallies, top-4 / runner-up / near-tie / selection path,
// best-idle, heartbeat age, lock/scan/admit stamps, queue context).

const (
	ctxModel      = "test/model-a-4bit"
	ctxOtherModel = "test/model-b-4bit"
)

func ctxRequest(model string) *PendingRequest {
	return &PendingRequest{
		RequestID:             "ctx-req",
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    256,
	}
}

func sumGateRejections(d RoutingDecision) int {
	total := 0
	for _, n := range d.GateRejections {
		total += int(n)
	}
	return total
}

func TestGateReasonNamesComplete(t *testing.T) {
	seen := map[string]bool{}
	for g := GateReason(0); g < GateReasonCount; g++ {
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
	if GateReasonCount.String() != "unknown" {
		t.Fatalf("GateReasonCount.String() = %q, want unknown", GateReasonCount.String())
	}
	for s := SelectionPath(0); s < selectionPathCount; s++ {
		if s.String() == "" || s.String() == "unknown" {
			t.Fatalf("SelectionPath %d has no name", s)
		}
	}
	want := map[string]string{
		"none": "none", "unique_min": "unique_min", "tie_queue": "tie_queue",
		"tie_pending": "tie_pending", "random": "random",
	}
	for _, s := range []SelectionPath{SelectionNone, SelectionUniqueMin, SelectionTieQueue, SelectionTiePending, SelectionRandom} {
		if _, ok := want[s.String()]; !ok {
			t.Fatalf("unexpected SelectionPath name %q", s.String())
		}
	}
}

func TestSlotStateFoldClosedVocabulary(t *testing.T) {
	cases := map[string]SlotState{
		"running": SlotStateRunning, "idle": SlotStateIdle, "idle_shutdown": SlotStateIdleShutdown,
		"crashed": SlotStateCrashed, "reloading": SlotStateReloading,
		"": SlotStateOther, "unknown": SlotStateOther, "RUNNING": SlotStateOther,
		"running; DROP TABLE": SlotStateOther, "totally-new-state": SlotStateOther,
	}
	for raw, want := range cases {
		if got := SlotStateFold(raw); got != want {
			t.Errorf("SlotStateFold(%q) = %q, want %q", raw, got, want)
		}
	}
	if got := ThermalStateFold("melting"); got != "other" {
		t.Errorf("ThermalStateFold(melting) = %q, want other", got)
	}
	if got := ThermalStateFold("serious"); got != "serious" {
		t.Errorf("ThermalStateFold(serious) = %q", got)
	}
}

// TestGateRejectionTallies drives one provider through each closed gate reason
// and asserts the decision tallies exactly that reason.
func TestGateRejectionTallies(t *testing.T) {
	ResetTTFTCalibration()
	type gateCase struct {
		name string
		want GateReason
		// model is the requested model (defaults to ctxModel).
		model string
		// withHealthy adds a second, fully eligible provider so the breaker /
		// ejection fail-open re-scan does not rescue the gated one.
		withHealthy bool
		// indexSkips: the gated provider does not advertise the model, so the
		// indexed scan never visits it (H4); see the not_serving_model case.
		indexSkips bool
		// setup mutates the gated provider / registry / request; returns the
		// excludeIDs to pass to ReserveProviderEx.
		setup func(t *testing.T, reg *Registry, p *Provider, pr *PendingRequest) []string
	}
	lock := func(p *Provider, f func()) {
		p.mu.Lock()
		defer p.mu.Unlock()
		f()
	}
	cases := []gateCase{
		{name: "offline", want: GateOffline, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.Status = StatusOffline })
			return nil
		}},
		{name: "untrusted", want: GateUntrusted, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.Status = StatusUntrusted })
			return nil
		}},
		{name: "trust_floor", want: GateTrustFloor, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.TrustLevel = TrustNone })
			return nil
		}},
		{name: "private_only", want: GatePrivateOnly, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.PrivateOnly = true })
			return nil
		}},
		{name: "runtime_unverified", want: GateRuntimeUnverified, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.RuntimeVerified = false })
			return nil
		}},
		{name: "private_text", want: GatePrivateText, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.EncryptedResponseChunks = false })
			return nil
		}},
		{name: "challenge_stale", want: GateChallengeStale, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.LastChallengeVerified = time.Now().Add(-time.Hour) })
			return nil
		}},
		{name: "trait_floor", want: GateTraitFloor, setup: func(_ *testing.T, _ *Registry, _ *Provider, pr *PendingRequest) []string {
			pr.Traits.MinPrefixCacheProtocol = 1
			return nil
		}},
		{name: "dedicated", want: GateDedicated, model: "mlx/gemma-4-ctx-4bit", setup: func(_ *testing.T, reg *Registry, p *Provider, _ *PendingRequest) []string {
			reg.SetDedicatedModels([]string{"gemma"})
			addAdvertisedModel(p, "mlx/qwen-ctx-4bit") // mixed box → not dedicated
			return nil
		}},
		{name: "dispatch_load_cooldown", want: GateDispatchLoadCooldown, setup: func(_ *testing.T, reg *Registry, p *Provider, pr *PendingRequest) []string {
			reg.RecordDispatchLoadFailure(p.ID, pr.Model)
			return nil
		}},
		{name: "error_cooldown", want: GateErrorCooldown, setup: func(_ *testing.T, reg *Registry, p *Provider, pr *PendingRequest) []string {
			for i := 0; i < inferenceErrorThreshold; i++ {
				reg.RecordInferenceError(p.ID, pr.Model, 500, pr.Traits.CooldownShape())
			}
			return nil
		}},
		{name: "capacity_cooldown", want: GateCapacityCooldown, setup: func(_ *testing.T, reg *Registry, p *Provider, pr *PendingRequest) []string {
			for i := 0; i < defaultCapacityCooldownThreshold; i++ {
				reg.RecordCapacityReject(p.ID, pr.Model)
			}
			return nil
		}},
		{name: "breaker", want: GateBreaker, withHealthy: true, setup: func(_ *testing.T, reg *Registry, p *Provider, _ *PendingRequest) []string {
			for i := 0; i < providerBreakerConsecTrip; i++ {
				reg.RecordProviderOutcome(p.ID, false, 500, "internal fault")
			}
			return nil
		}},
		{name: "ejection", want: GateEjection, withHealthy: true, setup: func(t *testing.T, reg *Registry, p *Provider, _ *PendingRequest) []string {
			if !healthEjectionEnabled() {
				t.Skip("health ejection disabled via env")
			}
			lock(p, func() {
				p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "EJECT-1"}
			})
			for i := 0; i < healthEjectionConsecTrip+healthEjectionMinSample; i++ {
				reg.RecordProviderServeOutcome("serial:EJECT-1", false, 500, "internal fault")
			}
			return nil
		}},
		{name: "slot_crashed", want: GateSlotCrashed, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.BackendCapacity.Slots[0].State = "crashed" })
			return nil
		}},
		{name: "slot_reloading", want: GateSlotReloading, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.BackendCapacity.Slots[0].State = "reloading" })
			return nil
		}},
		{name: "thermal_critical", want: GateThermalCritical, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.SystemMetrics.ThermalState = "critical" })
			return nil
		}},
		{name: "no_headroom", want: GateNoHeadroom, setup: func(_ *testing.T, _ *Registry, p *Provider, pr *PendingRequest) []string {
			lock(p, func() {
				p.BackendCapacity.Slots[0].MaxConcurrency = 1
				p.addPendingLocked(&PendingRequest{RequestID: "occupant", Model: pr.Model, RequestedMaxTokens: 64})
			})
			return nil
		}},
		{name: "model_too_large", want: GateModelTooLarge, setup: func(_ *testing.T, reg *Registry, p *Provider, pr *PendingRequest) []string {
			// Catalog says 128 GB minimum; the box has 64 GB and no resident slot.
			reg.SetModelCatalog([]CatalogEntry{{ID: pr.Model, MinRAMGB: 128, SizeGB: 100}})
			lock(p, func() { p.BackendCapacity.Slots = nil })
			return nil
		}},
		{name: "free_memory", want: GateFreeMemory, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			lock(p, func() { p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 100 })
			return nil
		}},
		{name: "vision", want: GateVision, setup: func(_ *testing.T, _ *Registry, _ *Provider, pr *PendingRequest) []string {
			pr.RequiresVision = true // provider advertises a text-only build
			return nil
		}},
		{name: "ttft_ceiling", want: GateTTFTCeiling, setup: func(_ *testing.T, _ *Registry, _ *Provider, pr *PendingRequest) []string {
			pr.MaxTTFTMs = 0.001
			return nil
		}},
		{name: "excluded", want: GateExcluded, setup: func(_ *testing.T, _ *Registry, p *Provider, _ *PendingRequest) []string {
			return []string{p.ID}
		}},
		{name: "allowlist", want: GateAllowlist, setup: func(_ *testing.T, _ *Registry, _ *Provider, pr *PendingRequest) []string {
			pr.AllowedProviderSerials = []string{"no-such-serial"}
			return nil
		}},
		// H4 (per-model index): the indexed scan never VISITS a provider that
		// does not advertise the model, so it reports Scanned 0 and no gate
		// tally at all; the GateNotServingModel tally only lands on the
		// brute-force walk (index disabled). indexSkips pins both shapes.
		{name: "not_serving_model", want: GateNotServingModel, indexSkips: true, setup: func(_ *testing.T, _ *Registry, _ *Provider, pr *PendingRequest) []string {
			pr.Model = ctxOtherModel
			return nil
		}},
		// H4, the other branch: an ADVERTISER of the requested model that fails
		// the catalog rule (public route, model absent from a non-nil catalog) IS
		// visited by the indexed scan and still tallies not_serving_model —
		// Scanned 1, CandidateSetSize 0.
		{name: "not_serving_model_off_catalog", want: GateNotServingModel, setup: func(_ *testing.T, reg *Registry, _ *Provider, _ *PendingRequest) []string {
			reg.SetModelCatalog([]CatalogEntry{{ID: ctxOtherModel, SizeGB: 1}})
			return nil
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			model := tc.model
			if model == "" {
				model = ctxModel
			}
			reg := New(testLogger())
			p := makeSchedulerProvider(t, reg, "gated", model, 40)
			var healthy *Provider
			if tc.withHealthy {
				healthy = makeSchedulerProvider(t, reg, "healthy", model, 40)
			}
			pr := ctxRequest(model)
			excludeIDs := tc.setup(t, reg, p, pr)
			winner, d := reg.ReserveProviderEx(pr.Model, pr, excludeIDs...)
			if tc.indexSkips {
				// Indexed walk: the non-advertiser is pruned before any gate runs.
				if winner != nil {
					t.Fatalf("indexed: winner = %s, want none", winner.ID)
				}
				if d.Scanned != 0 || d.CandidateSetSize != 0 || sumGateRejections(d) != 0 {
					t.Fatalf("indexed: scanned=%d set=%d rejections=%v, want 0/0/none", d.Scanned, d.CandidateSetSize, gateTallyMap(d))
				}
				// Brute-force walk: the legacy tally below still holds.
				reg.modelIndexDisabled = true
				winner, d = reg.ReserveProviderEx(pr.Model, pr, excludeIDs...)
				reg.modelIndexDisabled = false
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
			if tc.want == GateNotServingModel {
				wantSet--
			}
			if d.CandidateSetSize != wantSet {
				t.Fatalf("CandidateSetSize = %d, want %d", d.CandidateSetSize, wantSet)
			}
		})
	}
}

func gateTallyMap(d RoutingDecision) map[string]int {
	out := map[string]int{}
	for g := GateReason(0); g < GateReasonCount; g++ {
		if d.GateRejections[g] > 0 {
			out[g.String()] = int(d.GateRejections[g])
		}
	}
	return out
}

func mkCandidate(id string, cost float64, queue, pending int, discount float64) *routingCandidate {
	return &routingCandidate{
		provider:       &Provider{ID: id},
		costMs:         cost,
		effectiveQueue: queue,
		snapshot:       routingSnapshot{totalPending: pending},
		breakdown:      costBreakdown{CacheDiscountMs: discount, Total: cost},
	}
}

func TestSelectRoutingCandidatePaths(t *testing.T) {
	id := func(c *routingCandidate) string {
		if c == nil {
			return ""
		}
		return c.provider.ID
	}
	t.Run("empty", func(t *testing.T) {
		w, ru, n, path := selectRoutingCandidate(nil)
		if w != nil || ru != nil || n != 0 || path != SelectionNone {
			t.Fatalf("got %v %v %d %s", w, ru, n, path)
		}
	})
	t.Run("unique_min", func(t *testing.T) {
		a, b, c := mkCandidate("a", 1000, 0, 0, 0), mkCandidate("b", 10000, 0, 0, 0), mkCandidate("c", 20000, 0, 0, 0)
		w, ru, n, path := selectRoutingCandidate([]*routingCandidate{c, b, a})
		if id(w) != "a" || id(ru) != "b" || n != 1 || path != SelectionUniqueMin {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, path)
		}
	})
	t.Run("single_candidate", func(t *testing.T) {
		a := mkCandidate("a", 1000, 0, 0, 0)
		w, ru, n, path := selectRoutingCandidate([]*routingCandidate{a})
		if id(w) != "a" || ru != nil || n != 1 || path != SelectionUniqueMin {
			t.Fatalf("got winner=%s runnerUp=%v nearTie=%d path=%s", id(w), ru, n, path)
		}
	})
	t.Run("tie_queue", func(t *testing.T) {
		a, b := mkCandidate("a", 1000, 1, 0, 0), mkCandidate("b", 1500, 0, 0, 0)
		w, ru, n, path := selectRoutingCandidate([]*routingCandidate{a, b})
		if id(w) != "b" || id(ru) != "a" || n != 2 || path != SelectionTieQueue {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, path)
		}
	})
	t.Run("tie_pending", func(t *testing.T) {
		a, b := mkCandidate("a", 1000, 0, 2, 0), mkCandidate("b", 1500, 0, 1, 0)
		w, ru, n, path := selectRoutingCandidate([]*routingCandidate{a, b})
		if id(w) != "b" || id(ru) != "a" || n != 2 || path != SelectionTiePending {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, path)
		}
	})
	t.Run("random", func(t *testing.T) {
		a, b, far := mkCandidate("a", 1000, 0, 0, 0), mkCandidate("b", 1500, 0, 0, 0), mkCandidate("far", 50000, 0, 0, 0)
		for i := 0; i < 20; i++ {
			w, ru, n, path := selectRoutingCandidate([]*routingCandidate{far, a, b})
			if path != SelectionRandom || n != 2 {
				t.Fatalf("got nearTie=%d path=%s", n, path)
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
		a, b := mkCandidate("a", 1000, 0, 0, 0), mkCandidate("b", 900, 0, 0, 500)
		w, ru, n, path := selectRoutingCandidate([]*routingCandidate{a, b})
		if id(w) != "b" || id(ru) != "a" || n != 1 || path != SelectionUniqueMin {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, path)
		}
	})
	t.Run("cache_equal_random", func(t *testing.T) {
		a, b := mkCandidate("a", 900, 0, 0, 500), mkCandidate("b", 900, 0, 0, 500)
		_, _, _, path := selectRoutingCandidate([]*routingCandidate{a, b})
		if path != SelectionRandom {
			t.Fatalf("path = %s, want random", path)
		}
	})
	t.Run("discounted_minimum_keeps_cost_preference", func(t *testing.T) {
		a, b := mkCandidate("a", 500, 0, 0, 300), mkCandidate("b", 1000, 1, 0, 0)
		w, ru, n, path := selectRoutingCandidate([]*routingCandidate{b, a})
		if id(w) != "a" || id(ru) != "b" || n != 1 || path != SelectionUniqueMin {
			t.Fatalf("got winner=%s runnerUp=%s nearTie=%d path=%s", id(w), id(ru), n, path)
		}
	})
}

// TestReserveProviderExTopRunnerUpAndPath checks the top-4 ordering, the
// winner promotion to Top[0], the runner-up, and the unique_min path on a
// fleet whose per-request costs are separated by more than the near-tie window.
func TestReserveProviderExTopRunnerUpAndPath(t *testing.T) {
	ResetTTFTCalibration()
	reg := New(testLogger())
	for _, tps := range []float64{5, 10, 20, 40, 80} {
		makeSchedulerProvider(t, reg, "tps-"+itoa(int(tps)), ctxModel, tps)
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
	if d.SelectionPath != SelectionUniqueMin || d.NearTiePoolSize != 1 {
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
	if d.Top[0].SlotState != SlotStateRunning {
		t.Fatalf("Top[0].SlotState = %q, want running", d.Top[0].SlotState)
	}
	// Winner context.
	if d.RawTTFTMs <= 0 || d.TTFTMs != d.RawTTFTMs {
		t.Fatalf("TTFTMs=%v RawTTFTMs=%v, want equal and > 0 with the calibrator at 1.0", d.TTFTMs, d.RawTTFTMs)
	}
	if d.TTFTCalibrationRatio != 1.0 {
		t.Fatalf("TTFTCalibrationRatio = %v, want 1.0", d.TTFTCalibrationRatio)
	}
	if d.PrefillDecodeRatio != PrefillToDecodeRatio() {
		t.Fatalf("PrefillDecodeRatio = %v, want %v", d.PrefillDecodeRatio, PrefillToDecodeRatio())
	}
	if d.PendingForModel != 0 || d.TotalPending != 0 {
		t.Fatalf("pending = %d/%d, want 0/0", d.PendingForModel, d.TotalPending)
	}
	// Static 80 tok/s, batch 0 → projected per-request rate at batch 1.
	wantTPS := 80 / (1 + effectiveTPSLoadFactor)
	if math.Abs(d.PredictedDecodeTPS-wantTPS) > 1e-6 {
		t.Fatalf("PredictedDecodeTPS = %v, want %v", d.PredictedDecodeTPS, wantTPS)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

func TestReserveProviderExBestIdle(t *testing.T) {
	ResetTTFTCalibration()
	reg := New(testLogger())
	busyFast := makeSchedulerProvider(t, reg, "busy-fast", ctxModel, 80)
	busyFast.mu.Lock()
	busyFast.BackendCapacity.Slots[0].NumRunning = 2
	busyFast.mu.Unlock()
	idleSlow := makeSchedulerProvider(t, reg, "idle-slow", ctxModel, 10)
	idleSlow.mu.Lock()
	idleSlow.BackendCapacity.Slots[0].State = "idle"
	idleSlow.mu.Unlock()
	idleFast := makeSchedulerProvider(t, reg, "idle-fast", ctxModel, 40)
	idleFast.mu.Lock()
	idleFast.BackendCapacity.Slots[0].State = "idle"
	idleFast.mu.Unlock()

	pr := ctxRequest(ctxModel)
	winner, d := reg.ReserveProviderEx(ctxModel, pr)
	if winner == nil {
		t.Fatal("no winner")
	}
	winner.RemovePending(pr.RequestID)
	if !d.BestIdle.Present || d.BestIdle.ProviderID != "idle-fast" {
		t.Fatalf("BestIdle = %+v, want idle-fast", d.BestIdle)
	}
	if d.BestIdle.SlotState != SlotStateIdle || d.BestIdle.BackendRunning != 0 || d.BestIdle.BackendWaiting != 0 {
		t.Fatalf("BestIdle slot = %+v, want idle/0/0", d.BestIdle)
	}
	if d.BestIdle.TTFTMs <= 0 {
		t.Fatalf("BestIdle.TTFTMs = %v, want > 0", d.BestIdle.TTFTMs)
	}

	// Every warm slot busy → no best-idle.
	reg2 := New(testLogger())
	for _, id := range []string{"b1", "b2"} {
		p := makeSchedulerProvider(t, reg2, id, ctxModel, 40)
		p.mu.Lock()
		p.BackendCapacity.Slots[0].NumRunning = 1
		p.mu.Unlock()
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

func TestReserveProviderExSnapshotAgeAndPending(t *testing.T) {
	ResetTTFTCalibration()
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "aged", ctxModel, 40)
	addAdvertisedModel(p, ctxOtherModel)
	p.mu.Lock()
	p.LastHeartbeat = time.Now().Add(-7 * time.Second)
	p.addPendingLocked(&PendingRequest{RequestID: "other-model-req", Model: ctxOtherModel, RequestedMaxTokens: 64})
	p.mu.Unlock()

	pr := ctxRequest(ctxModel)
	winner, d := reg.ReserveProviderEx(ctxModel, pr)
	if winner == nil {
		t.Fatal("no winner")
	}
	winner.RemovePending(pr.RequestID)
	if d.SnapshotAgeMs < 6900 || d.SnapshotAgeMs > 9000 {
		t.Fatalf("SnapshotAgeMs = %d, want ≈ 7000", d.SnapshotAgeMs)
	}
	if int(d.Top[0].HBAgeMs) != d.SnapshotAgeMs {
		t.Fatalf("Top[0].HBAgeMs = %d, SnapshotAgeMs = %d", d.Top[0].HBAgeMs, d.SnapshotAgeMs)
	}
	if d.TotalPending != 1 || d.PendingForModel != 0 {
		t.Fatalf("TotalPending=%d PendingForModel=%d, want 1/0", d.TotalPending, d.PendingForModel)
	}
	if d.Top[0].TotalPending != 1 {
		t.Fatalf("Top[0].TotalPending = %d, want 1", d.Top[0].TotalPending)
	}
}

func TestHeartbeatAgeMsClamps(t *testing.T) {
	now := time.Now()
	if got := heartbeatAgeMs(now, time.Time{}); got != math.MaxInt32 {
		t.Fatalf("zero heartbeat age = %d, want MaxInt32", got)
	}
	if got := heartbeatAgeMs(now, now.Add(time.Second)); got != 0 {
		t.Fatalf("future heartbeat age = %d, want 0", got)
	}
	if got := heartbeatAgeMs(now, now.Add(-1500*time.Millisecond)); got != 1500 {
		t.Fatalf("age = %d, want 1500", got)
	}
}

func TestReserveProviderExStamps(t *testing.T) {
	ResetTTFTCalibration()
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "p1", ctxModel, 40)

	// Hold the registry write lock for a while so the lock-wait phase is
	// measurable and strictly ordered before the scan.
	const hold = 25 * time.Millisecond
	reg.mu.Lock()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		time.Sleep(hold)
		reg.mu.Unlock()
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

	// No-selection path: gate rejections + scan stamp, no admit phase.
	reg2 := New(testLogger())
	p := makeSchedulerProvider(t, reg2, "cold", ctxModel, 40)
	p.mu.Lock()
	p.Status = StatusOffline
	p.mu.Unlock()
	pr2 := ctxRequest(ctxModel)
	w2, d2 := reg2.ReserveProviderEx(ctxModel, pr2)
	if w2 != nil {
		t.Fatal("unexpected winner")
	}
	if d2.LockWaitUS < 0 || d2.ScanUS < 0 || d2.AdmitUS != 0 {
		t.Fatalf("no-selection stamps: lock=%d scan=%d admit=%d", d2.LockWaitUS, d2.ScanUS, d2.AdmitUS)
	}
	if d2.GateRejections[GateOffline] != 1 || d2.Scanned != 1 || d2.SelectionPath != SelectionNone {
		t.Fatalf("no-selection context: %v scanned=%d path=%s", gateTallyMap(d2), d2.Scanned, d2.SelectionPath)
	}
	if d2.Top[0].Present || d2.RunnerUp.Present || d2.BestIdle.Present {
		t.Fatalf("no-selection decision carries candidates: %+v", d2.Top[0])
	}
}

func TestQueueEnqueuePositionAndDepth(t *testing.T) {
	q := NewRequestQueue(8, time.Minute)
	for i := 0; i < 3; i++ {
		req := &QueuedRequest{RequestID: "q-" + itoa(i), Model: ctxModel}
		if err := q.Enqueue(req); err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
		if req.EnqueuePosition != i || req.DepthAtEnqueue != i {
			t.Fatalf("req %d: position=%d depth=%d, want %d/%d", i, req.EnqueuePosition, req.DepthAtEnqueue, i, i)
		}
	}
	if got := foldDrainTrigger("bogus"); got != DrainTriggerUnknown {
		t.Fatalf("foldDrainTrigger(bogus) = %q", got)
	}
	for _, r := range []string{DrainTriggerHeartbeat, DrainTriggerIdle, DrainTriggerChallenge, DrainTriggerLoad, DrainTriggerDisconnect, DrainTriggerKick} {
		if foldDrainTrigger(r) != r {
			t.Fatalf("foldDrainTrigger(%q) folded", r)
		}
	}
}

func TestDrainRecordsQueueContextAndTrigger(t *testing.T) {
	ResetTTFTCalibration()
	reg := New(testLogger())
	q := NewRequestQueue(8, time.Minute)
	reg.SetQueue(q)
	makeSchedulerProvider(t, reg, "p1", ctxModel, 40)

	head := &QueuedRequest{RequestID: "head", Model: ctxModel, Pending: ctxRequest(ctxModel)}
	head.Pending.RequestID = "head"
	second := &QueuedRequest{RequestID: "second", Model: ctxModel, Pending: ctxRequest(ctxModel)}
	second.Pending.RequestID = "second"
	for _, req := range []*QueuedRequest{head, second} {
		if err := q.Enqueue(req); err != nil {
			t.Fatalf("enqueue: %v", err)
		}
	}
	reg.drainQueuedRequestsForModelsWithReason([]string{ctxModel}, DrainTriggerHeartbeat)

	select {
	case p := <-head.ResponseCh:
		if p == nil {
			t.Fatal("head request failed")
		}
	default:
		t.Fatal("head request not assigned")
	}
	if head.DrainTrigger != DrainTriggerHeartbeat || head.Decision.DrainTrigger != DrainTriggerHeartbeat {
		t.Fatalf("drain trigger = %q / %q, want heartbeat", head.DrainTrigger, head.Decision.DrainTrigger)
	}
	if head.Decision.QueuePosition != 0 || head.Decision.QueueDepth != 0 {
		t.Fatalf("head queue context = %d/%d, want 0/0", head.Decision.QueuePosition, head.Decision.QueueDepth)
	}
	if head.Decision.ProviderID != "p1" {
		t.Fatalf("head decision provider = %q", head.Decision.ProviderID)
	}
	// second was enqueued behind head; whether it drained too depends only on
	// headroom, but its enqueue context is fixed at enqueue time.
	if second.EnqueuePosition != 1 || second.DepthAtEnqueue != 1 {
		t.Fatalf("second enqueue context = %d/%d, want 1/1", second.EnqueuePosition, second.DepthAtEnqueue)
	}

	// Legacy / un-migrated entry points fold to "unknown"; the exported
	// WithReason variants carry the api layer's bounded label through.
	drainVia := func(name string, drain func(r *Registry)) string {
		t.Helper()
		reg := New(testLogger())
		q := NewRequestQueue(8, time.Minute)
		reg.SetQueue(q)
		makeSchedulerProvider(t, reg, "p-"+name, ctxModel, 40)
		req := &QueuedRequest{RequestID: name, Model: ctxModel, Pending: ctxRequest(ctxModel)}
		req.Pending.RequestID = name
		if err := q.Enqueue(req); err != nil {
			t.Fatalf("enqueue: %v", err)
		}
		drain(reg)
		return req.DrainTrigger
	}
	if got := drainVia("legacy", func(r *Registry) { r.drainQueuedRequestsForModels([]string{ctxModel}) }); got != DrainTriggerUnknown {
		t.Fatalf("legacy drain trigger = %q, want unknown", got)
	}
	if got := drainVia("exported", func(r *Registry) { r.DrainQueuedRequestsForModel(ctxModel) }); got != DrainTriggerUnknown {
		t.Fatalf("DrainQueuedRequestsForModel trigger = %q, want unknown", got)
	}
	if got := drainVia("load", func(r *Registry) { r.DrainQueuedRequestsForModelWithReason(ctxModel, DrainTriggerLoad) }); got != DrainTriggerLoad {
		t.Fatalf("DrainQueuedRequestsForModelWithReason trigger = %q, want load", got)
	}
	if got := drainVia("challenge", func(r *Registry) {
		r.DrainQueuedRequestsForProviderWithReason(r.GetProvider("p-challenge"), DrainTriggerChallenge)
	}); got != DrainTriggerChallenge {
		t.Fatalf("DrainQueuedRequestsForProviderWithReason trigger = %q, want challenge", got)
	}
	if got := drainVia("bogus", func(r *Registry) { r.DrainQueuedRequestsForModelWithReason(ctxModel, "bogus") }); got != DrainTriggerUnknown {
		t.Fatalf("bogus reason folded to %q, want unknown", got)
	}
}

// TestCandidateSummaryIsFixedSize guards the allocation-free contract: the
// summary must never grow a slice/map/pointer field.
func TestCandidateSummaryIsFixedSize(t *testing.T) {
	c := &routingCandidate{
		provider: &Provider{ID: "x"},
		costMs:   1234,
		snapshot: routingSnapshot{slotState: "running", hbAgeMs: 42, totalPending: 3},
	}
	s := candidateSummaryOf(c)
	if !s.Present || s.ProviderID != "x" || s.CostMs != 1234 || s.SlotState != SlotStateRunning || s.HBAgeMs != 42 || s.TotalPending != 3 {
		t.Fatalf("summary = %+v", s)
	}
	if got := candidateSummaryOf(nil); got.Present {
		t.Fatalf("nil candidate summary present: %+v", got)
	}
	_ = protocol.SystemMetrics{} // keep protocol imported for fixture symmetry
}
