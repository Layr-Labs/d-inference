package registry

import (
	"math"
	"testing"
)

// TestLongPromptPrefillPenalty exercises the pure penalty helper across every
// behavior-preserving guard and the active amplification case. The helper now
// amplifies a supplied first-token-blocking time (ttftBlockMs) rather than a raw
// prefill rate, so the caller can fold in cold-load latency for unloaded boxes.
func TestLongPromptPrefillPenalty(t *testing.T) {
	origThreshold, origWeight := longPromptThresholdTokens, longPromptPrefillWeight
	defer func() { longPromptThresholdTokens, longPromptPrefillWeight = origThreshold, origWeight }()

	// Disabled (threshold 0): always 0, even for an enormous prompt / blocking time.
	longPromptThresholdTokens = 0
	longPromptPrefillWeight = 2.0
	if got := longPromptPenalty(100_000, 24_000); got != 0 {
		t.Fatalf("disabled penalty = %v, want 0", got)
	}

	// Enabled but prompt below the threshold: 0 (short prompts unaffected).
	longPromptThresholdTokens = 8_000
	if got := longPromptPenalty(4_000, 24_000); got != 0 {
		t.Fatalf("below-threshold penalty = %v, want 0", got)
	}

	// At/above the threshold: extra = (weight-1) * ttftBlockMs.
	// (2-1)*24000 = 24000ms.
	if got, want := longPromptPenalty(8_000, 24_000), 24_000.0; got != want {
		t.Fatalf("at-threshold penalty = %v, want %v", got, want)
	}

	// The amplified quantity is the FULL first-token-blocking time, so a candidate
	// with a larger ttftBlockMs gets a proportionally LARGER penalty. A cold box
	// (fast prefill but a ~30s load) therefore carries MORE penalty than the same
	// prefill alone — the cold-load latency is no longer amplified away. The delta
	// is exactly the amplified statePenalty.
	prefillOnly := longPromptPenalty(12_000, 6_000)                          // warm-style: prefill only
	withColdLoad := longPromptPenalty(12_000, 6_000+slotStatePenaltyUnknown) // cold: prefill + load
	if !(withColdLoad > prefillOnly) {
		t.Fatalf("cold-load ttft penalty %v should exceed prefill-only penalty %v", withColdLoad, prefillOnly)
	}
	if diff, want := withColdLoad-prefillOnly, (2.0-1.0)*slotStatePenaltyUnknown; diff != want {
		t.Fatalf("cold-load penalty delta = %v, want %v (the amplified statePenalty)", diff, want)
	}

	// Neutral weight (<=1) disables amplification even when the threshold is met.
	longPromptPrefillWeight = 1.0
	if got := longPromptPenalty(12_000, 24_000); got != 0 {
		t.Fatalf("neutral-weight penalty = %v, want 0", got)
	}

	// Non-positive blocking time: 0 (no penalty; guards the zero/garbage TTFT case).
	longPromptPrefillWeight = 2.0
	if got := longPromptPenalty(12_000, 0); got != 0 {
		t.Fatalf("zero-ttft penalty = %v, want 0", got)
	}
	if got := longPromptPenalty(12_000, -5); got != 0 {
		t.Fatalf("negative-ttft penalty = %v, want 0", got)
	}
}

// TestLongPromptSettersClampAndDefaults pins the default-off contract and the
// setter clamps so a misconfigured env var can never destabilize routing.
func TestLongPromptSettersClampAndDefaults(t *testing.T) {
	origThreshold, origWeight := longPromptThresholdTokens, longPromptPrefillWeight
	defer func() { longPromptThresholdTokens, longPromptPrefillWeight = origThreshold, origWeight }()

	if defaultLongPromptThresholdTokens != 0 {
		t.Fatalf("default threshold = %d, want 0 (preference off by default)", defaultLongPromptThresholdTokens)
	}

	SetLongPromptThreshold(8_000)
	if LongPromptThreshold() != 8_000 {
		t.Fatalf("threshold = %d, want 8000", LongPromptThreshold())
	}
	SetLongPromptThreshold(-5) // negative clamps to 0 (disabled)
	if LongPromptThreshold() != 0 {
		t.Fatalf("threshold = %d, want 0 after negative clamp", LongPromptThreshold())
	}

	SetLongPromptPrefillWeight(3.5)
	if LongPromptPrefillWeight() != 3.5 {
		t.Fatalf("weight = %v, want 3.5", LongPromptPrefillWeight())
	}
	SetLongPromptPrefillWeight(0.5) // sub-1 clamps to 1.0 (neutral)
	if LongPromptPrefillWeight() != 1.0 {
		t.Fatalf("weight = %v, want 1.0 after sub-1 clamp", LongPromptPrefillWeight())
	}

	// Non-finite weights (NaN/±Inf — e.g. EIGENINFERENCE_LONG_PROMPT_PREFILL_WEIGHT
	// =NaN/Inf) MUST NOT slip through the `< 1` clamp: NaN/Inf comparisons are
	// always false, so a stored NaN/Inf would yield a NaN/Inf penalty that poisons
	// every candidate cost and breaks the scheduler's `<`/near-tie comparisons.
	// They reset to the finite default so the weight is always well-defined.
	for _, bad := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		SetLongPromptPrefillWeight(bad)
		w := LongPromptPrefillWeight()
		if math.IsNaN(w) || math.IsInf(w, 0) {
			t.Fatalf("weight = %v after Set(%v), want a FINITE value", w, bad)
		}
		if w != defaultLongPromptPrefillWeight {
			t.Fatalf("weight = %v after Set(%v), want default %v", w, bad, defaultLongPromptPrefillWeight)
		}
	}
	// The default the non-finite guard restores must itself be the finite 2.0.
	if defaultLongPromptPrefillWeight != 2.0 {
		t.Fatalf("defaultLongPromptPrefillWeight = %v, want 2.0", defaultLongPromptPrefillWeight)
	}
}

// longPromptScenarioRegistry builds two providers that differ only in prefill
// rate plus a token-budget backlog handicap on the faster-prefill box:
//
//   - "fast-prefill": PrefillTPS=1000, 1800 tokens of active budget backlog
//     (≈18s of queue) so it is the WORSE choice for short prompts.
//   - "slow-prefill": PrefillTPS=500, idle (no backlog).
//
// Decode/effective TPS is pinned equal (100) on both so the only prompt-length-
// dependent difference in cost is the prefill term. The handicap is sized so the
// raw prefill gap alone (≈12s at 12k tokens) does NOT overcome it, but the
// amplified gap (weight 2) does — isolating the feature as the cause of the flip.
func longPromptScenarioRegistry(t *testing.T) (reg *Registry, model, fastID, slowID string) {
	t.Helper()
	reg = New(testLogger())
	model = "long-prompt-route-model"
	// observedTPS here is observed DECODE (pinned equal at 100); observed PREFILL
	// is left unset (0), so resolvePrefillTPS falls back to the static PrefillTPS
	// set below. Observed-vs-static prefill preference is covered separately by
	// TestLongPromptPrefersObservedOverStaticPrefill.
	fast := makeTokenBudgetProvider(t, reg, "fast-prefill", model, 100, 1_800, 200_000, 100)
	fast.mu.Lock()
	fast.PrefillTPS = 1_000
	fast.mu.Unlock()
	slow := makeTokenBudgetProvider(t, reg, "slow-prefill", model, 100, 0, 200_000, 100)
	slow.mu.Lock()
	slow.PrefillTPS = 500
	slow.mu.Unlock()
	return reg, model, fast.ID, slow.ID
}

// TestReserveProviderLongPromptPrefersFasterPrefill proves the long-prompt
// fastest-tier preference:
//  1. short prompts are unaffected (idle slow box still wins),
//  2. with the preference OFF a long prompt keeps the baseline winner, and
//  3. with the preference ON the same long prompt flips to the fastest-prefill box.
func TestReserveProviderLongPromptPrefersFasterPrefill(t *testing.T) {
	origThreshold, origWeight := longPromptThresholdTokens, longPromptPrefillWeight
	defer func() { longPromptThresholdTokens, longPromptPrefillWeight = origThreshold, origWeight }()

	// 1) Short prompt, preference ENABLED → short prompts unaffected: the idle
	//    slow-prefill provider (far lower total cost) still wins.
	SetLongPromptThreshold(8_000)
	SetLongPromptPrefillWeight(2.0)
	{
		reg, model, _, slowID := longPromptScenarioRegistry(t)
		sel, dec := reg.ReserveProviderEx(model, &PendingRequest{
			RequestID: "short", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 256,
		})
		if sel == nil {
			t.Fatalf("short prompt returned nil provider; decision=%+v", dec)
		}
		if sel.ID != slowID {
			t.Fatalf("short prompt selected %q, want idle slow-prefill %q (short prompts must be unaffected)", sel.ID, slowID)
		}
	}

	// 2) Long prompt, preference DISABLED → baseline: the slow box's backlog
	//    handicap is smaller than the raw prefill gap, so it still wins.
	SetLongPromptThreshold(0)
	{
		reg, model, _, slowID := longPromptScenarioRegistry(t)
		sel, dec := reg.ReserveProviderEx(model, &PendingRequest{
			RequestID: "long-off", Model: model, EstimatedPromptTokens: 12_000, RequestedMaxTokens: 256,
		})
		if sel == nil {
			t.Fatalf("long prompt (preference off) returned nil provider; decision=%+v", dec)
		}
		if sel.ID != slowID {
			t.Fatalf("long prompt with preference OFF selected %q, want %q (baseline must be unchanged)", sel.ID, slowID)
		}
	}

	// 3) Long prompt, preference ENABLED → the amplified prefill term flips the
	//    decision to the fastest-prefill provider.
	SetLongPromptThreshold(8_000)
	SetLongPromptPrefillWeight(2.0)
	{
		reg, model, fastID, _ := longPromptScenarioRegistry(t)
		sel, dec := reg.ReserveProviderEx(model, &PendingRequest{
			RequestID: "long-on", Model: model, EstimatedPromptTokens: 12_000, RequestedMaxTokens: 256,
		})
		if sel == nil {
			t.Fatalf("long prompt (preference on) returned nil provider; decision=%+v", dec)
		}
		if sel.ID != fastID {
			t.Fatalf("long prompt with preference ON selected %q, want fastest-prefill %q; decision=%+v", sel.ID, fastID, dec)
		}
		// The cost-breakdown invariant must still hold with the penalty folded in.
		sum := dec.StateMs + dec.QueueMs + dec.PendingMs + dec.BacklogMs + dec.ThisReqMs + dec.HealthMs
		if diff := sum - dec.CostMs; diff > 0.001 || diff < -0.001 {
			t.Fatalf("breakdown sum %f != CostMs %f (penalty must fold into ThisReqMs)", sum, dec.CostMs)
		}
	}
}

// TestLongPromptPrefersObservedOverStaticPrefill proves the long-prompt penalty
// ranks on resolvePrefillTPS (the observed-preferred live signal), not the static
// rate. A box with a fast STATIC prefill but degraded MEASURED prefill must lose
// a long prompt to a box with a slower static rate but faster measured prefill —
// exactly the misroute the static version would cause.
func TestLongPromptPrefersObservedOverStaticPrefill(t *testing.T) {
	origThreshold, origWeight := longPromptThresholdTokens, longPromptPrefillWeight
	defer func() { longPromptThresholdTokens, longPromptPrefillWeight = origThreshold, origWeight }()
	SetLongPromptThreshold(8_000)
	SetLongPromptPrefillWeight(2.0)

	reg := New(testLogger())
	model := "long-prompt-observed-model"
	// Static says A is the fast box; the live measured PREFILL says A is degraded
	// (200) and B is fast (2000). Both idle and equal on decode, so only the
	// prefill signal differs. observedTPS arg (observed decode) is pinned equal.
	staticFast := makeTokenBudgetProvider(t, reg, "static-fast-observed-slow", model, 100, 0, 200_000, 100)
	staticFast.mu.Lock()
	staticFast.PrefillTPS = 2_000
	staticFast.BackendCapacity.Slots[0].ObservedPrefillTPS = 200 // degraded live prefill
	staticFast.mu.Unlock()
	observedFast := makeTokenBudgetProvider(t, reg, "static-slow-observed-fast", model, 100, 0, 200_000, 100)
	observedFast.mu.Lock()
	observedFast.PrefillTPS = 400
	observedFast.BackendCapacity.Slots[0].ObservedPrefillTPS = 2_000 // fast live prefill
	observedFast.mu.Unlock()

	sel, dec := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID: "long-observed", Model: model, EstimatedPromptTokens: 12_000, RequestedMaxTokens: 256,
	})
	if sel == nil {
		t.Fatalf("returned nil provider; decision=%+v", dec)
	}
	if sel.ID != observedFast.ID {
		t.Fatalf("selected %q, want observed-fastest %q — the penalty must rank on resolvePrefillTPS, not static prefillTPS; decision=%+v",
			sel.ID, observedFast.ID, dec)
	}
}

// TestReserveProviderLongPromptColdLoadNotAmplifiedAway is the regression test for
// the cold-load bug: the long-prompt bias must amplify the FULL time-to-first-token
// (cold-load latency + prefill), not prefill alone. A COLD provider (model not
// loaded, "unknown" slot) with very fast prefill must NOT win a long prompt over a
// resident WARM provider whose slower prefill is still faster end-to-end once the
// cold box's ~30s load is counted.
//
// Numbers (threshold 8000, weight 2.0, 12k-token prompt, 256 max, decode 100,
// slotStatePenaltyUnknown 30000, health 550):
//
//	WARM (PrefillTPS 500, "running"): thisReq = 24000 prefill + 2560 decode +
//	    (2-1)*24000 penalty = 50560; +state 0 +health 550 => cost 51110.
//	COLD (PrefillTPS 2000, "unknown"): thisReq = 6000 prefill + 2560 decode +
//	    (2-1)*(6000+30000) penalty = 44560; +state 30000 +health 550 => cost 75110.
//
// Before the fix the cold penalty was only (2-1)*6000 and its 30000 load sat
// UN-amplified, so cold cost was 45110 < warm 51110 and the cold box wrongly won.
func TestReserveProviderLongPromptColdLoadNotAmplifiedAway(t *testing.T) {
	origThreshold, origWeight := longPromptThresholdTokens, longPromptPrefillWeight
	defer func() { longPromptThresholdTokens, longPromptPrefillWeight = origThreshold, origWeight }()
	SetLongPromptThreshold(8_000)
	SetLongPromptPrefillWeight(2.0)

	const (
		model          = "long-prompt-cold-load-model"
		reqPrompt      = 12_000
		reqMax         = 256
		warmPrefillTPS = 500.0
		coldPrefillTPS = 2_000.0
		decodeTPS      = 100.0
	)
	// Build a fresh warm+cold pair. Reservation mutates per-provider state, so each
	// route gets its own registry. The two differ only in prefill rate and whether
	// the model is resident: the WARM box is slower-prefill but loaded; the COLD
	// box is 4x faster-prefill but unloaded (an "unknown" slot => ~30s load).
	build := func(t *testing.T) (reg *Registry, warmID, coldID string) {
		t.Helper()
		reg = New(testLogger())
		warm := makeTokenBudgetProvider(t, reg, "warm-resident-slow-prefill", model, decodeTPS, 0, 200_000, decodeTPS)
		warm.mu.Lock()
		warm.PrefillTPS = warmPrefillTPS
		warm.BackendCapacity.Slots[0].State = "running" // model RESIDENT
		warm.mu.Unlock()
		cold := makeTokenBudgetProvider(t, reg, "cold-unloaded-fast-prefill", model, decodeTPS, 0, 200_000, decodeTPS)
		cold.mu.Lock()
		cold.PrefillTPS = coldPrefillTPS
		cold.BackendCapacity.Slots[0].State = "unknown" // model NOT loaded (~30s cold load)
		cold.mu.Unlock()
		return reg, warm.ID, cold.ID
	}

	// 1) End-to-end: the resident warm box wins the long prompt. CandidateCount == 2
	//    proves the cold box is a genuine, routable competitor (else this would be
	//    vacuously satisfied by the cold box being rejected outright).
	reg, warmID, _ := build(t)
	sel, dec := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID: "long-cold-vs-warm", Model: model, EstimatedPromptTokens: reqPrompt, RequestedMaxTokens: reqMax,
	})
	if sel == nil {
		t.Fatalf("returned nil provider; decision=%+v", dec)
	}
	if dec.CandidateCount != 2 {
		t.Fatalf("CandidateCount=%d, want 2 (cold box must be a real competitor, else the test is vacuous); decision=%+v", dec.CandidateCount, dec)
	}
	if sel.ID != warmID {
		t.Fatalf("long prompt selected %q, want resident warm %q — a cold box's fast prefill must not win once its ~30s load is amplified too; decision=%+v", sel.ID, warmID, dec)
	}
	if dec.StateMs != 0 {
		t.Fatalf("warm StateMs=%v, want 0 (resident box pays no cold-load penalty)", dec.StateMs)
	}

	// 2) Cost-level proof: route the cold box in isolation (exclude warm) and show
	//    its long-prompt cost now carries the AMPLIFIED cold-load term.
	regC, warmC, _ := build(t)
	coldSel, coldDec := regC.ReserveProviderEx(model, &PendingRequest{
		RequestID: "long-cold-only", Model: model, EstimatedPromptTokens: reqPrompt, RequestedMaxTokens: reqMax,
	}, warmC) // exclude warm => cold is the only candidate
	if coldSel == nil {
		t.Fatalf("cold-only route returned nil; decision=%+v", coldDec)
	}
	if coldDec.StateMs != slotStatePenaltyUnknown {
		t.Fatalf("cold StateMs=%v, want %v (unknown-slot cold-load penalty)", coldDec.StateMs, slotStatePenaltyUnknown)
	}
	coldPrefillMs := float64(reqPrompt) / coldPrefillTPS * 1000.0
	coldDecodeMs := float64(reqMax) / decodeTPS * 1000.0
	// With the fix the penalty amplifies prefill + cold load; pre-fix it amplified
	// prefill only (the 30000 load sat un-amplified in StateMs).
	wantColdThisReq := coldPrefillMs + coldDecodeMs + (2.0-1.0)*(coldPrefillMs+slotStatePenaltyUnknown)
	buggyColdThisReq := coldPrefillMs + coldDecodeMs + (2.0-1.0)*coldPrefillMs
	if math.Abs(coldDec.ThisReqMs-wantColdThisReq) > 0.001 {
		t.Fatalf("cold ThisReqMs=%v, want %v (prefill + decode + amplified full TTFT incl. cold load)", coldDec.ThisReqMs, wantColdThisReq)
	}
	if got, want := coldDec.ThisReqMs-buggyColdThisReq, (2.0-1.0)*slotStatePenaltyUnknown; math.Abs(got-want) > 0.001 {
		t.Fatalf("cold-load contribution to ThisReqMs = %v, want %v (the amplified statePenalty); pre-fix this was 0 and the cold box won", got, want)
	}
	// Cost-breakdown invariant still holds with the penalty folded into ThisReqMs.
	sum := coldDec.StateMs + coldDec.QueueMs + coldDec.PendingMs + coldDec.BacklogMs + coldDec.ThisReqMs + coldDec.HealthMs
	if math.Abs(sum-coldDec.CostMs) > 0.001 {
		t.Fatalf("cold breakdown sum %v != CostMs %v", sum, coldDec.CostMs)
	}
}
