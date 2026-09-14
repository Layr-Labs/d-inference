package faultstate

import (
	"math"
	"testing"
	"time"
)

// Below the minimum sample no penalty may apply, no matter how bad the rate —
// a tiny unlucky sample must not derate a healthy pair (fail-open).
func TestCapacityRateBelowMinSampleNoPenalty(t *testing.T) {
	r := newTestManager(testLogger())
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

// At or below the threshold the pair pays nothing: a box serving with
// occasional sheds keeps its normal ranking.
func TestCapacityRateAtThresholdNoPenalty(t *testing.T) {
	r := newTestManager(testLogger())
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
	r := newTestManager(testLogger())
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
	_, acceptHistory := rateHistoryOf(r, provider, model)
	accepts := countInWindow(acceptHistory, time.Now())
	if accepts != 7 {
		t.Fatalf("recent accept history = %d, want 7 after the new accept", accepts)
	}
}

// THE gray-box property: accepts must NOT reset the reject side of the window
// (that reset is the blindness being fixed). Contrast with the cooldown strike
// streak, which the same accept call deliberately clears.
func TestCapacityRateAcceptsDoNotResetRejects(t *testing.T) {
	r := newTestManager(testLogger())
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
	strikes := -1
	readGateForSession(r, provider, func(g *gateState) {
		if g != nil {
			strikes = len(g.capacityRejectStrikes[model])
		}
	})
	if strikes != 0 {
		t.Fatalf("cooldown strikes = %d after accepts, want 0 (accept-reset is the cooldown's contract)", strikes)
	}
}

// One served request counts ONE outcome: the completion-time accept after a
// commit-time accept must not double-count (countRateOutcome=false), or the
// denominator dilutes and the measured rate reads low.
func TestCapacityRateOutcomeDedupe(t *testing.T) {
	r := newTestManager(testLogger())
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
	r := newTestManager(testLogger())
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
	r := newTestManager(testLogger())
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
	r := newTestManager(testLogger())
	const provider, model = "prov-rate-env", "gemma-4-26b-qat-4bit"

	seedRateOutcomes(r, provider, model, 4, 6) // rate 0.4
	penalty, _ := capacityRatePenaltyOf(r, provider, model)
	if want := 0.4 * 30_000.0; math.Abs(penalty-want) > 1e-6 {
		t.Fatalf("penalty = %v, want %v with EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS=30000", penalty, want)
	}
}

// capacityRatePenaltyOf reads the pair's penalty and rate under the lock, as
// buildCandidateWithReason does.
func capacityRatePenaltyOf(r *testManager, providerID, model string) (penaltyMs, rate float64) {
	return r.capacityRatePenalty(providerID, model, time.Now())
}

// rateHistoryOf returns copies of the pair's windowed reject/accept histories.
func rateHistoryOf(r *testManager, providerID, model string) (rejects, accepts []time.Time) {
	readGateForSession(r, providerID, func(g *gateState) {
		if g == nil {
			return
		}
		rejects = append([]time.Time(nil), g.capacityRateRejects[model]...)
		accepts = append([]time.Time(nil), g.capacityRateAccepts[model]...)
	})
	return rejects, accepts
}

// seedRateOutcomes drives the real entry points in reject-first order. Other
// tests cover accept-first and interleaved ordering explicitly.
func seedRateOutcomes(r *testManager, providerID, model string, rejects, accepts int) {
	for i := 0; i < rejects; i++ {
		r.RecordCapacityReject(providerID, model)
	}
	for i := 0; i < accepts; i++ {
		r.RecordCapacityAcceptOutcome(providerID, model, true)
	}
}

// ageCapacityRateRejects rewinds the pair's reject outcomes by d.
func ageCapacityRateRejects(r *testManager, providerID, model string, d time.Duration) {
	withGateForSession(r, providerID, func(g *gateState) {
		outcomes := g.capacityRateRejects[model]
		aged := make([]time.Time, len(outcomes))
		for i, ts := range outcomes {
			aged[i] = ts.Add(-d)
		}
		g.capacityRateRejects[model] = aged
	})
}
