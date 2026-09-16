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
	return r.capacityRatePenalty(providerID, model, time.Now())
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
