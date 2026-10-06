package registry_test

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/longprompt"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const slotStatePenaltyUnknown = 30_000.0

// TestLongPromptPrefillPenalty exercises the pure penalty helper across every
// behavior-preserving guard and the active amplification case. The helper now
// amplifies a supplied first-token-blocking time (ttftBlockMs) rather than a raw
// prefill rate, so the caller can fold in cold-load latency for unloaded boxes.
func TestLongPromptPrefillPenalty(t *testing.T) {
	// Disabled (threshold 0): always 0, even for an enormous prompt / blocking time.
	longPromptThresholdTokens := 0
	longPromptPrefillWeight := 2.0
	if got := longprompt.Penalty(100_000, 24_000, longPromptThresholdTokens, longPromptPrefillWeight); got != 0 {
		t.Fatalf("disabled penalty = %v, want 0", got)
	}

	// Enabled but prompt below the threshold: 0 (short prompts unaffected).
	longPromptThresholdTokens = 8_000
	if got := longprompt.Penalty(4_000, 24_000, longPromptThresholdTokens, longPromptPrefillWeight); got != 0 {
		t.Fatalf("below-threshold penalty = %v, want 0", got)
	}

	// At/above the threshold: extra = (weight-1) * ttftBlockMs.
	// (2-1)*24000 = 24000ms.
	if got, want := longprompt.Penalty(8_000, 24_000, longPromptThresholdTokens, longPromptPrefillWeight), 24_000.0; got != want {
		t.Fatalf("at-threshold penalty = %v, want %v", got, want)
	}

	// The amplified quantity is the FULL first-token-blocking time, so a candidate
	// with a larger ttftBlockMs gets a proportionally LARGER penalty. A cold box
	// (fast prefill but a ~30s load) therefore carries MORE penalty than the same
	// prefill alone — the cold-load latency is no longer amplified away. The delta
	// is exactly the amplified statePenalty.
	prefillOnly := longprompt.Penalty(12_000, 6_000, longPromptThresholdTokens, longPromptPrefillWeight)                          // warm-style: prefill only
	withColdLoad := longprompt.Penalty(12_000, 6_000+slotStatePenaltyUnknown, longPromptThresholdTokens, longPromptPrefillWeight) // cold: prefill + load
	if !(withColdLoad > prefillOnly) {
		t.Fatalf("cold-load ttft penalty %v should exceed prefill-only penalty %v", withColdLoad, prefillOnly)
	}
	if diff, want := withColdLoad-prefillOnly, (2.0-1.0)*slotStatePenaltyUnknown; diff != want {
		t.Fatalf("cold-load penalty delta = %v, want %v (the amplified statePenalty)", diff, want)
	}

	// Neutral weight (<=1) disables amplification even when the threshold is met.
	longPromptPrefillWeight = 1.0
	if got := longprompt.Penalty(12_000, 24_000, longPromptThresholdTokens, longPromptPrefillWeight); got != 0 {
		t.Fatalf("neutral-weight penalty = %v, want 0", got)
	}

	// Non-positive blocking time: 0 (no penalty; guards the zero/garbage TTFT case).
	longPromptPrefillWeight = 2.0
	if got := longprompt.Penalty(12_000, 0, longPromptThresholdTokens, longPromptPrefillWeight); got != 0 {
		t.Fatalf("zero-ttft penalty = %v, want 0", got)
	}
	if got := longprompt.Penalty(12_000, -5, longPromptThresholdTokens, longPromptPrefillWeight); got != 0 {
		t.Fatalf("negative-ttft penalty = %v, want 0", got)
	}
}

// TestLongPromptSettersClampAndDefaults pins the default-off contract and the
// setter clamps so a misconfigured env var can never destabilize routing.
func TestLongPromptSettersClampAndDefaults(t *testing.T) {
	origThreshold, origWeight := production.LongPromptThreshold(), production.LongPromptPrefillWeight()
	defer func() {
		production.SetLongPromptThreshold(origThreshold)
		production.SetLongPromptPrefillWeight(origWeight)
	}()

	if longprompt.DefaultThresholdTokens != 0 {
		t.Fatalf("default threshold = %d, want 0 (preference off by default)", longprompt.DefaultThresholdTokens)
	}

	production.SetLongPromptThreshold(8_000)
	if production.LongPromptThreshold() != 8_000 {
		t.Fatalf("threshold = %d, want 8000", production.LongPromptThreshold())
	}
	production.SetLongPromptThreshold(-5) // negative clamps to 0 (disabled)
	if production.LongPromptThreshold() != 0 {
		t.Fatalf("threshold = %d, want 0 after negative clamp", production.LongPromptThreshold())
	}

	production.SetLongPromptPrefillWeight(3.5)
	if production.LongPromptPrefillWeight() != 3.5 {
		t.Fatalf("weight = %v, want 3.5", production.LongPromptPrefillWeight())
	}
	production.SetLongPromptPrefillWeight(0.5) // sub-1 clamps to 1.0 (neutral)
	if production.LongPromptPrefillWeight() != 1.0 {
		t.Fatalf("weight = %v, want 1.0 after sub-1 clamp", production.LongPromptPrefillWeight())
	}

	// Non-finite weights (NaN/±Inf — e.g. EIGENINFERENCE_LONG_PROMPT_PREFILL_WEIGHT
	// =NaN/Inf) MUST NOT slip through the `< 1` clamp: NaN/Inf comparisons are
	// always false, so a stored NaN/Inf would yield a NaN/Inf penalty that poisons
	// every candidate cost and breaks the scheduler's `<`/near-tie comparisons.
	// They reset to the finite default so the weight is always well-defined.
	for _, bad := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		production.SetLongPromptPrefillWeight(bad)
		w := production.LongPromptPrefillWeight()
		if math.IsNaN(w) || math.IsInf(w, 0) {
			t.Fatalf("weight = %v after Set(%v), want a FINITE value", w, bad)
		}
		if w != longprompt.DefaultPrefillWeight {
			t.Fatalf("weight = %v after Set(%v), want default %v", w, bad, longprompt.DefaultPrefillWeight)
		}
	}
	// The default the non-finite guard restores must itself be the finite 2.0.
	if longprompt.DefaultPrefillWeight != 2.0 {
		t.Fatalf("defaultLongPromptPrefillWeight = %v, want 2.0", longprompt.DefaultPrefillWeight)
	}
}

// longPromptScenarioRegistry builds two providers that differ only in prefill
// rate plus a token-budget memory commitment on the faster-prefill box:
//
//   - "fast-prefill": PrefillTPS=1000, 1800 tokens of active budget commitment.
//   - "slow-prefill": PrefillTPS=500, no active budget commitment.
//
// Decode/effective TPS is pinned equal (100) on both so the only prompt-length-
// dependent difference is the prefill term. Memory commitments remain admission
// inputs and legacy cost diagnostics; they do not represent queued service work.
func longPromptScenarioRegistry(t *testing.T) (reg *production.Registry, model, fastID, slowID string) {
	t.Helper()
	reg = production.New(testLogger())
	model = "long-prompt-route-model"
	// observedTPS here is observed DECODE (pinned equal at 100); observed PREFILL
	// is left unset (0), so resolvePrefillTPS falls back to the static PrefillTPS
	// set below. Observed-vs-static prefill preference is covered separately by
	// TestLongPromptPrefersObservedOverStaticPrefill.
	fast := makeTokenBudgetProvider(t, reg, "fast-prefill", model, 100, 1_800, 200_000, 100)
	fast.Mu().Lock()
	fast.PrefillTPS = 1_000
	fast.Mu().Unlock()
	slow := makeTokenBudgetProvider(t, reg, "slow-prefill", model, 100, 0, 200_000, 100)
	slow.Mu().Lock()
	slow.PrefillTPS = 500
	slow.Mu().Unlock()
	return reg, model, fast.ID, slow.ID
}

// First-content selection prefers faster prefill for long requests without
// needing the historical diagnostic cost multiplier. Short requests within the
// 100-ms band spread across providers with equal committed service work.
func TestReserveProviderLongPromptPrefersFasterPrefill(t *testing.T) {
	origThreshold, origWeight := production.LongPromptThreshold(), production.LongPromptPrefillWeight()
	defer func() {
		production.SetLongPromptThreshold(origThreshold)
		production.SetLongPromptPrefillWeight(origWeight)
	}()

	// 1) The 100-token prompt puts both providers within the 100-ms fast band.
	//    Both have zero reported or reserved service work, so either may win.
	production.SetLongPromptThreshold(8_000)
	production.SetLongPromptPrefillWeight(2.0)
	{
		reg, model, fastID, slowID := longPromptScenarioRegistry(t)
		sel, dec := reg.ReserveProviderEx(model, &production.PendingRequest{
			RequestID: "short", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 256,
		})
		if sel == nil {
			t.Fatalf("short prompt returned nil provider; decision=%+v", dec)
		}
		if (sel.ID != fastID && sel.ID != slowID) || dec.NearTiePoolSize != 2 || dec.SelectionPath != production.SelectionRandom {
			t.Fatalf("short prompt selected %q with band=%d path=%s; want either equally committed provider in a random two-provider band", sel.ID, dec.NearTiePoolSize, dec.SelectionPath)
		}
	}

	// 2) The new first-content policy already selects the faster provider
	//    with historical long-prompt cost weighting disabled.
	production.SetLongPromptThreshold(0)
	{
		reg, model, fastID, _ := longPromptScenarioRegistry(t)
		sel, dec := reg.ReserveProviderEx(model, &production.PendingRequest{
			RequestID: "long-off", Model: model, EstimatedPromptTokens: 12_000, RequestedMaxTokens: 256,
		})
		if sel == nil {
			t.Fatalf("long prompt (preference off) returned nil provider; decision=%+v", dec)
		}
		if sel.ID != fastID {
			t.Fatalf("first-content policy selected %q, want %q without legacy weighting", sel.ID, fastID)
		}
	}

	// 3) Historical cost diagnostics still price the multiplier, but do not
	//    change the first-content winner.
	production.SetLongPromptThreshold(8_000)
	production.SetLongPromptPrefillWeight(2.0)
	{
		reg, model, fastID, _ := longPromptScenarioRegistry(t)
		sel, dec := reg.ReserveProviderEx(model, &production.PendingRequest{
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
	origThreshold, origWeight := production.LongPromptThreshold(), production.LongPromptPrefillWeight()
	defer func() {
		production.SetLongPromptThreshold(origThreshold)
		production.SetLongPromptPrefillWeight(origWeight)
	}()
	production.SetLongPromptThreshold(8_000)
	production.SetLongPromptPrefillWeight(2.0)

	reg := production.New(testLogger())
	model := "long-prompt-observed-model"
	// Static says A is the fast box; the live measured PREFILL says A is degraded
	// (200) and B is fast (2000). Both idle and equal on decode, so only the
	// prefill signal differs. observedTPS arg (observed decode) is pinned equal.
	staticFast := makeTokenBudgetProvider(t, reg, "static-fast-observed-slow", model, 100, 0, 200_000, 100)
	staticFast.Mu().Lock()
	staticFast.PrefillTPS = 2_000
	staticFast.BackendCapacity.Slots[0].ObservedPrefillTPS = 200 // degraded live prefill
	staticFast.Mu().Unlock()
	observedFast := makeTokenBudgetProvider(t, reg, "static-slow-observed-fast", model, 100, 0, 200_000, 100)
	observedFast.Mu().Lock()
	observedFast.PrefillTPS = 400
	observedFast.BackendCapacity.Slots[0].ObservedPrefillTPS = 2_000 // fast live prefill
	observedFast.Mu().Unlock()

	sel, dec := reg.ReserveProviderEx(model, &production.PendingRequest{
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
	origThreshold, origWeight := production.LongPromptThreshold(), production.LongPromptPrefillWeight()
	defer func() {
		production.SetLongPromptThreshold(origThreshold)
		production.SetLongPromptPrefillWeight(origWeight)
	}()
	production.SetLongPromptThreshold(8_000)
	production.SetLongPromptPrefillWeight(2.0)

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
	build := func(t *testing.T) (reg *production.Registry, warmID, coldID string) {
		t.Helper()
		reg = production.New(testLogger())
		warm := makeTokenBudgetProvider(t, reg, "warm-resident-slow-prefill", model, decodeTPS, 0, 200_000, decodeTPS)
		warm.Mu().Lock()
		warm.PrefillTPS = warmPrefillTPS
		warm.BackendCapacity.Slots[0].State = "running" // model RESIDENT
		warm.Mu().Unlock()
		cold := makeTokenBudgetProvider(t, reg, "cold-unloaded-fast-prefill", model, decodeTPS, 0, 200_000, decodeTPS)
		cold.Mu().Lock()
		cold.PrefillTPS = coldPrefillTPS
		cold.BackendCapacity.Slots[0].State = "unknown" // model NOT loaded (~30s cold load)
		cold.Mu().Unlock()
		return reg, warm.ID, cold.ID
	}

	// 1) End-to-end: the resident warm box wins the long prompt. CandidateCount == 2
	//    proves the cold box is a genuine, routable competitor (else this would be
	//    vacuously satisfied by the cold box being rejected outright).
	reg, warmID, _ := build(t)
	sel, dec := reg.ReserveProviderEx(model, &production.PendingRequest{
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
	coldSel, coldDec := regC.ReserveProviderEx(model, &production.PendingRequest{
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

// TestRoutingCostPrefersObservedOverStaticPrefill is the regression test for the
// base routing cost term. TestLongPromptPrefersObservedOverStaticPrefill above
// only exercises the long-prompt bias, which is OFF by default
// (defaultLongPromptThresholdTokens == 0, and longPromptPenalty returns 0 at a
// non-positive threshold). With the bias off, the prefill contribution to cost is
// thisReqMs alone — so if thisReqMs reads the static snap.prefillTPS, the measured
// prefill EWMA cannot influence provider selection at all on a default
// configuration, and a box whose live prefill has degraded keeps winning on the
// strength of its registration benchmark.
//
// Same fixture shape as the long-prompt test, with the threshold pinned OFF and a
// prompt well below any bias.
func TestRoutingCostPrefersObservedOverStaticPrefill(t *testing.T) {
	origThreshold, origWeight := production.LongPromptThreshold(), production.LongPromptPrefillWeight()
	defer func() {
		production.SetLongPromptThreshold(origThreshold)
		production.SetLongPromptPrefillWeight(origWeight)
	}()
	// Pin the documented default: the long-prompt bias contributes nothing, so
	// only the base cost term can express the prefill difference.
	production.SetLongPromptThreshold(0)

	reg := production.New(testLogger())
	model := "routing-cost-observed-prefill-model"
	// Static says A is the fast box; the live measured PREFILL says A is degraded
	// (200) and B is fast (2000). Both idle and equal on decode, so the prefill
	// signal is the only thing that differs.
	staticFast := makeTokenBudgetProvider(t, reg, "static-fast-observed-slow", model, 100, 0, 200_000, 100)
	staticFast.Mu().Lock()
	staticFast.PrefillTPS = 2_000
	staticFast.BackendCapacity.Slots[0].ObservedPrefillTPS = 200 // degraded live prefill
	staticFast.Mu().Unlock()
	observedFast := makeTokenBudgetProvider(t, reg, "static-slow-observed-fast", model, 100, 0, 200_000, 100)
	observedFast.Mu().Lock()
	observedFast.PrefillTPS = 400
	observedFast.BackendCapacity.Slots[0].ObservedPrefillTPS = 2_000 // fast live prefill
	observedFast.Mu().Unlock()

	sel, dec := reg.ReserveProviderEx(model, &production.PendingRequest{
		RequestID: "routing-cost-observed", Model: model, EstimatedPromptTokens: 4_000, RequestedMaxTokens: 256,
	})
	if sel == nil {
		t.Fatalf("returned nil provider; decision=%+v", dec)
	}
	if sel.ID != observedFast.ID {
		t.Fatalf("selected %q, want observed-fastest %q — the base cost term must price prefill with resolvePrefillTPS, not the static snap.prefillTPS; decision=%+v",
			sel.ID, observedFast.ID, dec)
	}
	// The cost-breakdown invariant must still hold after the hoist.
	sum := dec.StateMs + dec.QueueMs + dec.PendingMs + dec.BacklogMs + dec.ThisReqMs + dec.HealthMs
	if diff := sum - dec.CostMs; diff > 0.001 || diff < -0.001 {
		t.Fatalf("breakdown sum %f != CostMs %f", sum, dec.CostMs)
	}
}
