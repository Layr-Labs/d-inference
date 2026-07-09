package registry

import (
	"math"
	"testing"
	"time"
)

// Tests for the capacity-503 rate penalty (capacity_rate.go): the gray-box
// derater. Unlike every zero-interleaved-accepts breaker, the rate window has
// NO accept-triggered reset — a pair failing a material fraction of dispatches
// while serving the rest accumulates an honest reject rate and pays a
// proportional cost penalty; nothing is ejected and the penalty decays as
// outcomes age out.

// capacityRatePenaltyOf reads the pair's penalty and rate under the lock, as
// buildCandidateWithReason does.
func capacityRatePenaltyOf(r *Registry, providerID, model string) (penaltyMs, rate float64) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.capacityRatePenaltyLocked(providerID, model, time.Now())
}

// seedRateOutcomes drives the real entry points in reject-first order. Other
// tests cover accept-first and interleaved ordering explicitly.
func seedRateOutcomes(r *Registry, providerID, model string, rejects, accepts int) {
	for i := 0; i < rejects; i++ {
		r.RecordCapacityReject(providerID, model)
	}
	for i := 0; i < accepts; i++ {
		r.RecordCapacityAcceptOutcome(providerID, model, true)
	}
}

// ageCapacityRateRejects rewinds the pair's reject outcomes by d.
func ageCapacityRateRejects(r *Registry, providerID, model string, d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: model}
	outcomes := r.capacityRateRejects[key]
	aged := make([]time.Time, len(outcomes))
	for i, ts := range outcomes {
		aged[i] = ts.Add(-d)
	}
	r.capacityRateRejects[key] = aged
}

// Below the minimum sample no penalty may apply, no matter how bad the rate —
// a tiny unlucky sample must not derate a healthy pair (fail-open).
func TestCapacityRateBelowMinSampleNoPenalty(t *testing.T) {
	r := New(testLogger())
	const provider, model = "prov-small-sample", "gemma-4-26b-qat-4bit"

	seedRateOutcomes(r, provider, model, 3, 2) // 5 outcomes, rate 0.6
	if penalty, rate := capacityRatePenaltyOf(r, provider, model); penalty != 0 {
		t.Fatalf("penalty = %v with only 5 outcomes (rate %.2f), want 0 below minSample %d", penalty, rate, capacityRateMinSample)
	}
	// Crossing the sample floor with the rate still above threshold turns the
	// penalty on: 4R + 6A = 10 outcomes, rate 0.4.
	seedRateOutcomes(r, provider, model, 1, 4)
	penalty, rate := capacityRatePenaltyOf(r, provider, model)
	if math.Abs(rate-0.4) > 1e-9 {
		t.Fatalf("rate = %v, want 0.4", rate)
	}
	if want := 0.4 * defaultCapacityRatePenaltyMs; math.Abs(penalty-want) > 1e-6 {
		t.Fatalf("penalty = %v, want rate x default = %v", penalty, want)
	}
}

// The penalty is proportional to the rate and lands in the routing cost —
// visible on the winning RoutingDecision's cost breakdown — while a pair at or
// below the threshold pays nothing.
func TestCapacityRatePenaltyInRoutingCost(t *testing.T) {
	t.Setenv(envBudgetClamp, "false") // isolate the rate mechanism from the clamp
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "rated-box", model, 100, 0, 5_000_000, 100)

	// 4 rejects + 6 accepts = rate 0.4 over 10 outcomes.
	seedRateOutcomes(r, p.ID, model, 4, 6)

	sel, decision := r.ReserveProviderEx(model, &PendingRequest{
		RequestID: "rate-cost", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 256,
	})
	if sel == nil {
		t.Fatal("penalized pair must STILL be routable (derated, never ejected)")
	}
	sel.RemovePending("rate-cost")
	r.SetProviderIdle(sel.ID)

	wantPenalty := 0.4 * defaultCapacityRatePenaltyMs
	if math.Abs(decision.CapacityRateMs-wantPenalty) > 1e-6 {
		t.Fatalf("decision.CapacityRateMs = %v, want %v", decision.CapacityRateMs, wantPenalty)
	}
	if math.Abs(decision.CapacityRejectRate-0.4) > 1e-9 {
		t.Fatalf("decision.CapacityRejectRate = %v, want 0.4", decision.CapacityRejectRate)
	}
	// The breakdown-sum invariant must hold with the new term.
	sum := decision.StateMs + decision.QueueMs + decision.PendingMs +
		decision.BacklogMs + decision.ThisReqMs + decision.HealthMs + decision.CapacityRateMs
	if diff := sum - decision.CostMs; diff > 0.001 || diff < -0.001 {
		t.Fatalf("breakdown sum %f != CostMs %f", sum, decision.CostMs)
	}
}

// At or below the threshold the pair pays nothing: a box serving with
// occasional sheds keeps its normal ranking.
func TestCapacityRateAtThresholdNoPenalty(t *testing.T) {
	r := New(testLogger())
	const provider, model = "prov-threshold", "gemma-4-26b-qat-4bit"

	// 2 rejects + 6 accepts = rate 0.25 == threshold (not strictly above).
	seedRateOutcomes(r, provider, model, 2, 6)
	if penalty, rate := capacityRatePenaltyOf(r, provider, model); penalty != 0 {
		t.Fatalf("penalty = %v at rate %.2f == threshold, want 0 (strictly-above semantics)", penalty, rate)
	}
}

// Outcomes age out of the window naturally — no reset event required. Once the
// rejects decay the penalty is gone, while still-recent accepts remain hidden
// but available to the next reject window.
func TestCapacityRateDecays(t *testing.T) {
	r := New(testLogger())
	const provider, model = "prov-decay", "gemma-4-26b-qat-4bit"

	seedRateOutcomes(r, provider, model, 4, 6)
	if penalty, _ := capacityRatePenaltyOf(r, provider, model); penalty <= 0 {
		t.Fatal("setup: penalty must be active at rate 0.4")
	}
	ageCapacityRateRejects(r, provider, model, capacityRateWindow+time.Second)
	if penalty, rate := capacityRatePenaltyOf(r, provider, model); penalty != 0 || rate != 0 {
		t.Fatalf("penalty=%v rate=%v after the rejects aged out, want 0/0", penalty, rate)
	}
	// A later accept keeps the recent denominator warm. The stale reject slice is
	// observationally inert; accept history must not be deleted just because the
	// last reject expired.
	r.RecordCapacityAcceptOutcome(provider, model, true)
	r.mu.RLock()
	key := capacityRejectKey{ProviderID: provider, ModelID: model}
	accepts := countInWindow(r.capacityRateAccepts[key], time.Now())
	r.mu.RUnlock()
	if accepts != 7 {
		t.Fatalf("recent accept history = %d, want 7 after the new accept", accepts)
	}
}

// THE gray-box property: accepts must NOT reset the reject side of the window
// (that reset is the blindness being fixed). Contrast with the cooldown strike
// streak, which the same accept call deliberately clears.
func TestCapacityRateAcceptsDoNotResetRejects(t *testing.T) {
	r := New(testLogger())
	const provider, model = "prov-noreset", "gemma-4-26b-qat-4bit"

	seedRateOutcomes(r, provider, model, 4, 0)
	for i := 0; i < 6; i++ {
		r.RecordCapacityAccept(provider, model)
	}
	rate, samples := r.CapacityRejectRate(provider, model)
	if samples != 10 || math.Abs(rate-0.4) > 1e-9 {
		t.Fatalf("rate window after interleaved accepts = (rate %.2f, samples %d), want (0.40, 10) — accepts must add to the denominator, never wipe the rejects", rate, samples)
	}
	// The cooldown strike streak WAS cleared by those accepts (its designed
	// discriminator) — proving the two trackers are decoupled.
	r.mu.RLock()
	strikes := len(r.capacityRejectStrikes[capacityRejectKey{ProviderID: provider, ModelID: model}])
	r.mu.RUnlock()
	if strikes != 0 {
		t.Fatalf("cooldown strikes = %d after accepts, want 0 (accept-reset is the cooldown's contract)", strikes)
	}
}

// One served request counts ONE outcome: the completion-time accept after a
// commit-time accept must not double-count (countRateOutcome=false), or the
// denominator dilutes and the measured rate reads low.
func TestCapacityRateOutcomeDedupe(t *testing.T) {
	r := New(testLogger())
	const provider, model = "prov-dedupe", "gemma-4-26b-qat-4bit"

	seedRateOutcomes(r, provider, model, 4, 0)
	for i := 0; i < 6; i++ {
		r.RecordCapacityAcceptOutcome(provider, model, true)  // commit-time
		r.RecordCapacityAcceptOutcome(provider, model, false) // completion-time (same request)
	}
	rate, samples := r.CapacityRejectRate(provider, model)
	if samples != 10 {
		t.Fatalf("samples = %d, want 10 — the completion-time accept double-counted", samples)
	}
	if math.Abs(rate-0.4) > 1e-9 {
		t.Fatalf("rate = %v, want 0.4", rate)
	}
}

// A benign lifecycle capacity miss (cold "model not loaded" lazy-load) must
// feed the black-hole cooldown but must NOT derate the gray-box capacity-503
// RATE: that window has no accept-reset, so counting a healthy box's normal
// reloads would penalize it as if its reported budget were dishonest. Contrast
// RecordCapacityReject, which DOES derate. Codex review of #523.
func TestCapacityRateLifecycleRejectFeedsCooldownNotRate(t *testing.T) {
	r := New(testLogger())
	const provider, model = "prov-lifecycle", "gemma-4-26b-qat-4bit"

	// A pure run of lifecycle cold-404 misses (no accepts) must still trip the
	// black-hole cooldown — a box that never loads is a black hole.
	for i := 0; i < defaultCapacityCooldownThreshold; i++ {
		r.RecordCapacityRejectLifecycle(provider, model)
	}
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("lifecycle cold-404 misses must still feed the black-hole cooldown (forever-404 = black hole)")
	}
	// ...but they must NOT have accumulated any gray-box capacity-503 rate.
	if rate, samples := r.CapacityRejectRate(provider, model); samples != 0 || rate != 0 {
		t.Fatalf("lifecycle misses derated the rate: rate=%.2f samples=%d, want 0/0 (the rate window must ignore cold-load misses)", rate, samples)
	}

	// A GENUINE derating reject on a fresh pair DOES accumulate the rate,
	// proving the two entry points diverge only on the rate window.
	const genuine = "prov-genuine"
	seedRateOutcomes(r, genuine, model, capacityRateMinSample, 0)
	if _, samples := r.CapacityRejectRate(genuine, model); samples != capacityRateMinSample {
		t.Fatalf("genuine capacity rejects must derate: samples=%d, want %d", samples, capacityRateMinSample)
	}
}

// Kill switch: EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS=0 disables recording
// and the penalty entirely.
func TestCapacityRateKillSwitch(t *testing.T) {
	t.Setenv(envCapacityRatePenaltyMs, "0")
	r := New(testLogger())
	const provider, model = "prov-rate-off", "gemma-4-26b-qat-4bit"

	seedRateOutcomes(r, provider, model, 10, 2)
	if penalty, rate := capacityRatePenaltyOf(r, provider, model); penalty != 0 || rate != 0 {
		t.Fatalf("disabled tracker returned penalty=%v rate=%v, want 0/0", penalty, rate)
	}
	if _, samples := r.CapacityRejectRate(provider, model); samples != 0 {
		t.Fatalf("disabled tracker recorded %d outcomes, want 0", samples)
	}
}

// The env tunable scales the penalty.
func TestCapacityRatePenaltyEnvTunable(t *testing.T) {
	t.Setenv(envCapacityRatePenaltyMs, "30000")
	r := New(testLogger())
	const provider, model = "prov-rate-env", "gemma-4-26b-qat-4bit"

	seedRateOutcomes(r, provider, model, 4, 6) // rate 0.4
	penalty, _ := capacityRatePenaltyOf(r, provider, model)
	if want := 0.4 * 30_000.0; math.Abs(penalty-want) > 1e-6 {
		t.Fatalf("penalty = %v, want %v with EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS=30000", penalty, want)
	}
}

// The rate window keys by STABLE identity: disconnect/reconnect with the same
// serial keeps the accumulated outcomes.
func TestCapacityRateSurvivesReconnect(t *testing.T) {
	r := New(testLogger())
	const model, serial = "gemma-4-26b-qat-4bit", "SER-RATE"

	p1 := attestSchedulerProvider(t, r, "rate-sess-1", model, serial, 100)
	seedRateOutcomes(r, p1.ID, model, 4, 6)
	r.Disconnect("rate-sess-1")

	p2 := attestSchedulerProvider(t, r, "rate-sess-2", model, serial, 100)
	rate, samples := r.CapacityRejectRate(p2.ID, model)
	if samples != 10 || math.Abs(rate-0.4) > 1e-9 {
		t.Fatalf("rate window after reconnect = (rate %.2f, samples %d), want (0.40, 10) — the window was wiped by the reconnect", rate, samples)
	}
	if penalty, _ := capacityRatePenaltyOf(r, p2.ID, model); penalty <= 0 {
		t.Fatal("penalty must still apply through the reconnected session")
	}
}

// The penalty derates without ejecting: with every peer WORSE than the
// penalized pair, the pair still serves (the fail-open selection machinery is
// untouched).
func TestCapacityRateNeverClosesRouting(t *testing.T) {
	t.Setenv(envBudgetClamp, "false")
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "only-box", model, 100, 0, 5_000_000, 100)

	// Drive the rate high (0.75, well over the sample floor) while keeping
	// accepts interleaved, so the pair COOLDOWN (zero-interleaved-accepts
	// discriminator) never trips and the rate penalty is the mechanism under
	// test.
	for i := 0; i < 4; i++ {
		seedRateOutcomes(r, p.ID, model, 3, 1)
	}
	sel, decision := r.ReserveProviderEx(model, &PendingRequest{
		RequestID: "sole", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 256,
	})
	if sel == nil {
		t.Fatalf("a fully-penalized pair must remain routable when it is the only candidate (decision: %+v)", decision)
	}
	sel.RemovePending("sole")
	if decision.CapacityRateMs <= 0 {
		t.Fatal("penalty must be visible on the decision")
	}
}

// A stream that commits BEFORE the pair's first windowed reject is retained at
// commit, so later rejects see it immediately and completion must not count it
// again. This is the exactly-once contract behind RateOutcomeCountedSafe.
func TestCapacityRatePreRejectCommitCountsExactlyOnce(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "pre-reject-commit", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)

	// Long stream commits first content while the pair is healthy. Its accept is
	// dormant until a reject arrives, but it is already retained and stamped.
	if recorded := r.RecordCapacityAccept(p.ID, model); !recorded {
		t.Fatal("commit-time accept must be retained before the first reject")
	}

	// The box goes gray while the stream is still serving: 8 capacity-503s.
	for i := 0; i < capacityRateMinSample; i++ {
		r.RecordCapacityReject(p.ID, model)
	}

	// Completion sees RateOutcomeCountedSafe=true and passes false, so it cannot
	// add the request a second time.
	if recorded := r.RecordCapacityAcceptOutcome(p.ID, model, false); recorded {
		t.Fatal("completion after a pre-reject commit must not record a second outcome")
	}

	rate, samples := r.CapacityRejectRate(p.ID, model)
	if samples != capacityRateMinSample+1 {
		t.Fatalf("samples = %d, want %d (8 rejects + the served stream)", samples, capacityRateMinSample+1)
	}
	wantRate := float64(capacityRateMinSample) / float64(capacityRateMinSample+1)
	if rate != wantRate {
		t.Fatalf("rate = %v, want %v — the served stream must be in the denominator", rate, wantRate)
	}

	// And the double-count guard: a request that commits DURING the reject
	// window records at commit (offer returns true), so its completion-time
	// call passes countRateOutcome=false and adds nothing.
	if recorded := r.RecordCapacityAccept(p.ID, model); !recorded {
		t.Fatal("commit-time accept with rejects in-window must record")
	}
	if recorded := r.RecordCapacityAcceptOutcome(p.ID, model, false); recorded {
		t.Fatal("completion after a recorded commit must not record a second outcome")
	}
	if _, samples := r.CapacityRejectRate(p.ID, model); samples != capacityRateMinSample+2 {
		t.Fatalf("samples = %d, want %d — one request must count exactly once", samples, capacityRateMinSample+2)
	}
}
