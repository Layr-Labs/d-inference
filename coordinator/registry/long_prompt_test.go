package registry

import "testing"

// TestLongPromptPrefillPenalty exercises the pure penalty helper across every
// behavior-preserving guard and the active amplification case (DAR-330).
func TestLongPromptPrefillPenalty(t *testing.T) {
	origThreshold, origWeight := longPromptThresholdTokens, longPromptPrefillWeight
	defer func() { longPromptThresholdTokens, longPromptPrefillWeight = origThreshold, origWeight }()

	// Disabled (threshold 0): always 0, even for an enormous prompt.
	longPromptThresholdTokens = 0
	longPromptPrefillWeight = 2.0
	if got := longPromptPrefillPenalty(100_000, 500); got != 0 {
		t.Fatalf("disabled penalty = %v, want 0", got)
	}

	// Enabled but prompt below the threshold: 0 (short prompts unaffected).
	longPromptThresholdTokens = 8_000
	if got := longPromptPrefillPenalty(4_000, 500); got != 0 {
		t.Fatalf("below-threshold penalty = %v, want 0", got)
	}

	// At the threshold: extra = (weight-1) * prompt/prefillTPS*1000.
	// 8000/500*1000 = 16000ms; (2-1)*16000 = 16000ms.
	if got, want := longPromptPrefillPenalty(8_000, 500), 16_000.0; got != want {
		t.Fatalf("at-threshold penalty = %v, want %v", got, want)
	}

	// The whole point: a faster-prefill provider gets a proportionally SMALLER
	// penalty for the same long prompt, biasing selection to the fastest tier.
	slow := longPromptPrefillPenalty(12_000, 500)   // 12000/500*1000=24000 -> 24000
	fast := longPromptPrefillPenalty(12_000, 1_000) // 12000/1000*1000=12000 -> 12000
	if !(fast < slow) {
		t.Fatalf("faster-prefill penalty %v should be < slower-prefill penalty %v", fast, slow)
	}

	// Neutral weight (<=1) disables amplification even when the threshold is met.
	longPromptPrefillWeight = 1.0
	if got := longPromptPrefillPenalty(12_000, 500); got != 0 {
		t.Fatalf("neutral-weight penalty = %v, want 0", got)
	}

	// Unknown prefill rate: 0 (no divide-by-zero, no penalty).
	longPromptPrefillWeight = 2.0
	if got := longPromptPrefillPenalty(12_000, 0); got != 0 {
		t.Fatalf("zero-prefill penalty = %v, want 0", got)
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
// fastest-tier preference (DAR-330):
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
