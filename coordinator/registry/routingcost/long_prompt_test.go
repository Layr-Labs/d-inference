package routingcost

import (
	"math"
	"testing"
)

// TestLongPromptPrefillPenalty exercises the pure penalty helper across every
// behavior-preserving guard and the active amplification case. The helper now
// amplifies a supplied first-token-blocking time (ttftBlockMs) rather than a raw
// prefill rate, so the caller can fold in cold-load latency for unloaded boxes.
func TestLongPromptPrefillPenalty(t *testing.T) {
	origThreshold, origWeight := routingPolicy.longPromptThresholdTokens, routingPolicy.longPromptPrefillWeight
	defer func() {
		routingPolicy.longPromptThresholdTokens, routingPolicy.longPromptPrefillWeight = origThreshold, origWeight
	}()

	// Disabled (threshold 0): always 0, even for an enormous prompt / blocking time.
	routingPolicy.longPromptThresholdTokens = 0
	routingPolicy.longPromptPrefillWeight = 2.0
	if got := routingPolicy.LongPromptPenalty(100_000, 24_000); got != 0 {
		t.Fatalf("disabled penalty = %v, want 0", got)
	}

	// Enabled but prompt below the threshold: 0 (short prompts unaffected).
	routingPolicy.longPromptThresholdTokens = 8_000
	if got := routingPolicy.LongPromptPenalty(4_000, 24_000); got != 0 {
		t.Fatalf("below-threshold penalty = %v, want 0", got)
	}

	// At/above the threshold: extra = (weight-1) * ttftBlockMs.
	// (2-1)*24000 = 24000ms.
	if got, want := routingPolicy.LongPromptPenalty(8_000, 24_000), 24_000.0; got != want {
		t.Fatalf("at-threshold penalty = %v, want %v", got, want)
	}

	// The amplified quantity is the FULL first-token-blocking time, so a candidate
	// with a larger ttftBlockMs gets a proportionally LARGER penalty. A cold box
	// (fast prefill but a ~30s load) therefore carries MORE penalty than the same
	// prefill alone — the cold-load latency is no longer amplified away. The delta
	// is exactly the amplified statePenalty.
	prefillOnly := routingPolicy.LongPromptPenalty(12_000, 6_000)                          // warm-style: prefill only
	withColdLoad := routingPolicy.LongPromptPenalty(12_000, 6_000+SlotStatePenaltyUnknown) // cold: prefill + load
	if !(withColdLoad > prefillOnly) {
		t.Fatalf("cold-load ttft penalty %v should exceed prefill-only penalty %v", withColdLoad, prefillOnly)
	}
	if diff, want := withColdLoad-prefillOnly, (2.0-1.0)*SlotStatePenaltyUnknown; diff != want {
		t.Fatalf("cold-load penalty delta = %v, want %v (the amplified statePenalty)", diff, want)
	}

	// Neutral weight (<=1) disables amplification even when the threshold is met.
	routingPolicy.longPromptPrefillWeight = 1.0
	if got := routingPolicy.LongPromptPenalty(12_000, 24_000); got != 0 {
		t.Fatalf("neutral-weight penalty = %v, want 0", got)
	}

	// Non-positive blocking time: 0 (no penalty; guards the zero/garbage TTFT case).
	routingPolicy.longPromptPrefillWeight = 2.0
	if got := routingPolicy.LongPromptPenalty(12_000, 0); got != 0 {
		t.Fatalf("zero-ttft penalty = %v, want 0", got)
	}
	if got := routingPolicy.LongPromptPenalty(12_000, -5); got != 0 {
		t.Fatalf("negative-ttft penalty = %v, want 0", got)
	}
}

// TestLongPromptSettersClampAndDefaults pins the default-off contract and the
// setter clamps so a misconfigured env var can never destabilize routing.
func TestLongPromptSettersClampAndDefaults(t *testing.T) {
	origThreshold, origWeight := routingPolicy.longPromptThresholdTokens, routingPolicy.longPromptPrefillWeight
	defer func() {
		routingPolicy.longPromptThresholdTokens, routingPolicy.longPromptPrefillWeight = origThreshold, origWeight
	}()

	if DefaultLongPromptThresholdTokens != 0 {
		t.Fatalf("default threshold = %d, want 0 (preference off by default)", DefaultLongPromptThresholdTokens)
	}

	routingPolicy.SetLongPromptThreshold(8_000)
	if routingPolicy.LongPromptThreshold() != 8_000 {
		t.Fatalf("threshold = %d, want 8000", routingPolicy.LongPromptThreshold())
	}
	routingPolicy.SetLongPromptThreshold(-5) // negative clamps to 0 (disabled)
	if routingPolicy.LongPromptThreshold() != 0 {
		t.Fatalf("threshold = %d, want 0 after negative clamp", routingPolicy.LongPromptThreshold())
	}

	routingPolicy.SetLongPromptPrefillWeight(3.5)
	if routingPolicy.LongPromptPrefillWeight() != 3.5 {
		t.Fatalf("weight = %v, want 3.5", routingPolicy.LongPromptPrefillWeight())
	}
	routingPolicy.SetLongPromptPrefillWeight(0.5) // sub-1 clamps to 1.0 (neutral)
	if routingPolicy.LongPromptPrefillWeight() != 1.0 {
		t.Fatalf("weight = %v, want 1.0 after sub-1 clamp", routingPolicy.LongPromptPrefillWeight())
	}

	// Non-finite weights (NaN/±Inf — e.g. EIGENINFERENCE_LONG_PROMPT_PREFILL_WEIGHT
	// =NaN/Inf) MUST NOT slip through the `< 1` clamp: NaN/Inf comparisons are
	// always false, so a stored NaN/Inf would yield a NaN/Inf penalty that poisons
	// every candidate cost and breaks the scheduler's `<`/near-tie comparisons.
	// They reset to the finite default so the weight is always well-defined.
	for _, bad := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		routingPolicy.SetLongPromptPrefillWeight(bad)
		w := routingPolicy.LongPromptPrefillWeight()
		if math.IsNaN(w) || math.IsInf(w, 0) {
			t.Fatalf("weight = %v after Set(%v), want a FINITE value", w, bad)
		}
		if w != DefaultLongPromptPrefillWeight {
			t.Fatalf("weight = %v after Set(%v), want default %v", w, bad, DefaultLongPromptPrefillWeight)
		}
	}
	// The default the non-finite guard restores must itself be the finite 2.0.
	if DefaultLongPromptPrefillWeight != 2.0 {
		t.Fatalf("defaultLongPromptPrefillWeight = %v, want 2.0", DefaultLongPromptPrefillWeight)
	}
}
