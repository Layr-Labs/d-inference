package registry

// Scope pins for the expected-completion routing term (completion_calibration.go):
// ExpectedCompletionTokens may change RANKING only. Every gate that mirrors
// the provider's own prompt+max_tokens ledger — pendingTokenBudget, the
// free-memory/budget admission inside the scan, the capacity preflight and
// PredictServable — must keep reading RequestedMaxTokens. A provider that has
// room for prompt+expected but not prompt+bound must therefore REJECT the
// request; relaxing any of these below the forwarded bound would admit
// requests the provider's ledger refuses (admit -> token_budget_exhausted 503
// -> budget_clamp / capacity cooldowns against healthy pairs).

import (
	"fmt"
	"testing"
)

func TestExpectedCompletionNeverReachesAdmission(t *testing.T) {
	const (
		model    = "expected-leak-model"
		prompt   = 100
		bound    = 16384
		expected = 500
	)
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})
	// Budget admits prompt+expected (600) but not prompt+bound (16,484).
	p := makeTokenBudgetProvider(t, reg, "expected-leak-p1", model, 40, 0, prompt+expected+100, 40)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].MaxConcurrency = 4
	p.mu.Unlock()

	routingOnly := &PendingRequest{RequestID: "routing-only", Model: model, EstimatedPromptTokens: prompt, RequestedMaxTokens: bound, ExpectedCompletionTokens: expected}
	control := &PendingRequest{RequestID: "control", Model: model, EstimatedPromptTokens: prompt, RequestedMaxTokens: expected}

	cases := []struct {
		gate string
		run  func() (rejected bool, detail string)
	}{
		{"pendingTokenBudget", func() (bool, string) {
			got := pendingTokenBudget(routingOnly)
			return got == prompt+bound, fmt.Sprintf("pendingTokenBudget=%d (want prompt+bound %d)", got, prompt+bound)
		}},
		{"ReserveProviderEx free-memory/budget admission", func() (bool, string) {
			sel, dec := reg.ReserveProviderEx(model, routingOnly)
			if sel != nil {
				sel.RemovePending(routingOnly.RequestID)
			}
			return sel == nil && dec.CapacityRejections > 0, fmt.Sprintf("selected=%v decision=%+v", sel != nil, dec)
		}},
		// The preflight and the servability gate take the max-tokens bound as
		// a plain int and never see a PendingRequest, so these two rows only
		// show that a bound which does not fit is rejected — they cannot, by
		// construction, prove the routing-only value is not passed in. The
		// call-site pin in api (TestAdmissionGatesNeverReceiveExpectedCompletion)
		// is what proves every caller passes requestedMaxTokens.
		{"QuickCapacityCheck preflight (bound rejected)", func() (bool, string) {
			cc, capRej, _, _, _ := reg.QuickCapacityCheckWithTTFTForRequest(model, prompt, bound, RequestTraits{}, false)
			return cc == 0 && capRej == 1, fmt.Sprintf("candidates=%d capacityRejections=%d", cc, capRej)
		}},
		{"PredictServable (bound rejected)", func() (bool, string) {
			v := reg.PredictServable(model, prompt, prompt, bound, 0, RequestTraits{}, false)
			return !v.Servable, fmt.Sprintf("verdict=%+v", v)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.gate, func(t *testing.T) {
			if rejected, detail := tc.run(); !rejected {
				t.Fatalf("%s admitted a request whose forwarded bound does not fit: the routing-only ExpectedCompletionTokens leaked into admission (%s)", tc.gate, detail)
			}
		})
	}

	// Control: the same provider admits the request when the BOUND fits, and
	// the ranking term is the only thing the expected value moved.
	sel, ctrlDec := reg.ReserveProviderEx(model, control)
	if sel == nil {
		t.Fatalf("control reservation (bound %d) rejected: %+v", expected, ctrlDec)
	}
	sel.RemovePending(control.RequestID)
	if cc, _, _, _, _ := reg.QuickCapacityCheckWithTTFTForRequest(model, prompt, expected, RequestTraits{}, false); cc != 1 {
		t.Fatalf("control preflight candidates=%d, want 1", cc)
	}
	if v := reg.PredictServable(model, prompt, prompt, expected, 0, RequestTraits{}, false); !v.Servable {
		t.Fatalf("control PredictServable = %+v, want servable", v)
	}
}

// TestAlgorithm_P3_LoadDistributesAcrossIdleProvidersAtInjectedBound is the
// P3 distribution scenario at the injected max_output_length (32,768): with
// the bound in the decode term the Ultra (80 tok/s) takes ~100% of arrivals
// because 32,768/60 − 32,768/80 ≈ 137 s dwarfs the 3 s near-tie window; with a
// warm calibrator (p90 ~460 → expected 574) the three idle tiers share load
// again (≤70% on any one), exactly as they do at 256 today.
func TestAlgorithm_P3_LoadDistributesAcrossIdleProvidersAtInjectedBound(t *testing.T) {
	const bound = 32_768
	run := func(t *testing.T, expected int) map[string]int {
		reg := New(testLogger())
		model := "p3-injected-bound-model"
		reg.SetModelCatalog([]CatalogEntry{{ID: model}})
		scenarioProvider{id: "ultra", decodeTPS: 80, totalMemGB: 512}.register(t, reg, model)
		scenarioProvider{id: "max", decodeTPS: 60, totalMemGB: 128}.register(t, reg, model)
		scenarioProvider{id: "pro", decodeTPS: 20, totalMemGB: 24}.register(t, reg, model)
		counts := map[string]int{}
		for i := 0; i < 100; i++ {
			pr := &PendingRequest{
				RequestID:                fmt.Sprintf("dist-%d", i),
				Model:                    model,
				RequestedMaxTokens:       bound,
				ExpectedCompletionTokens: expected,
			}
			p := reg.ReserveProvider(model, pr)
			if p == nil {
				t.Fatalf("reservation %d returned nil", i)
			}
			counts[p.ID]++
			p.RemovePending(pr.RequestID)
			reg.SetProviderIdle(p.ID)
		}
		return counts
	}

	t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "on")
	// Today's failure mode (documented, not fixed by the bound alone).
	uncal := run(t, 0)
	if share := highestShare(uncal, 100); share <= 0.70 {
		t.Fatalf("with the 32,768 bound in the decode term the dominant share is %.0f%% (%v); this scenario is expected to herd", share*100, uncal)
	}
	// Warm calibrator: expected = clamp(p90 × 1.25, 64, 32,768) ≈ 574.
	reg := New(testLogger())
	seedCompletionWindow(reg, "seed", 50, 100, 500)
	expected := reg.ExpectedCompletionTokens("seed", bound)
	if expected < 400 || expected > 700 {
		t.Fatalf("seeded expected=%d, want ~574", expected)
	}
	cal := run(t, expected)
	if share := highestShare(cal, 100); share > 0.70 {
		t.Fatalf("dominant provider has %.0f%% of selections at the injected bound with a warm calibrator (counts=%v); want ≤70%%", share*100, cal)
	}
}
