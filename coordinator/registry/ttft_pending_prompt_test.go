package registry

import (
	"math"
	"testing"
)

// These are deterministic synthetic workload comparisons, not provider timing
// measurements. The real preflight and reserve paths must price known prompt
// work consistently before a heartbeat reflects the outstanding reservation.
func TestTTFTPendingPromptComparison(t *testing.T) {
	for _, tc := range []struct {
		name                  string
		pending, incoming     int
		ceiling, legacy, want float64
		admit                 bool
	}{
		{"short_behind_long", 4000, 100, 3000, 210, 4110, false},
		{"long_behind_short", 100, 4000, 5000, 8010, 4110, true},
		{"equal_prompts", 500, 500, 2000, 1010, 1010, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resetCalibrator(t)
			reg := New(testLogger())
			model := "pending-" + tc.name
			p := calibrationTestProvider(t, reg, "pending-box", model, 100, 1000)
			pending := &PendingRequest{RequestID: "ahead", Model: model, EstimatedPromptTokens: tc.pending, RequestedMaxTokens: 1}
			if selected, d := reg.ReserveProviderEx(model, pending); selected == nil {
				t.Fatalf("reserve ahead: %+v", d)
			}
			_, _, _, preflight, known := reg.QuickCapacityCheckWithTTFTForRequest(model, tc.incoming, 1, RequestTraits{}, false)
			if !known || math.Abs(float64(preflight.Microseconds())/1000-tc.want) > 0.001 {
				t.Fatalf("preflight=%v known=%v, want %vms", preflight, known, tc.want)
			}
			pr := &PendingRequest{RequestID: "arriving", Model: model, EstimatedPromptTokens: tc.incoming, RequestedMaxTokens: 1, MaxTTFTMs: tc.ceiling}
			selected, d := reg.ReserveProviderEx(model, pr)
			if (selected != nil) != tc.admit || math.Abs(d.BestTTFTMs-tc.want) > 0.001 {
				t.Fatalf("selected=%v decision=%+v, want admit=%v estimate=%v", selected != nil, d, tc.admit, tc.want)
			}
			p.RemovePending(pr.RequestID)
			// The existing online calibrator still applies to the corrected raw
			// work estimate; model/chip hierarchy and thresholds are unchanged.
			feedObservations(t, model, p.Hardware.ChipFamily, ttftCalibrationWarmupObs, 0.5)
			_, _, _, calibrated, known := reg.QuickCapacityCheckWithTTFTForRequest(model, tc.incoming, 1, RequestTraits{}, false)
			if !known || math.Abs(float64(calibrated.Microseconds())/1000-tc.want*0.5) > 0.001 {
				t.Fatalf("calibrated=%v known=%v, want %vms", calibrated, known, tc.want*0.5)
			}
			t.Logf("synthetic cohort=%s incoming_requests=1 existing_reservations=1 raw_before_ms=%.0f raw_after_ms=%.0f calibrated_before_ms=%.0f calibrated_after_ms=%.0f ceiling_ms=%.0f admitted_before=%v admitted_after=%v actual_provider_ms=unknown final_request_outcome=unknown", tc.name, tc.legacy, tc.want, tc.legacy*0.5, tc.want*0.5, tc.ceiling, tc.legacy <= tc.ceiling, tc.admit)
		})
	}
}

func TestTTFTPendingPromptSnapshotBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name      string
		prompt    int
		incoming  int
		committed bool
		other     bool
		running   int
		waiting   int
		want      float64
	}{
		{"content_already_committed", 4000, 100, true, false, 0, 0, 110},
		{"other_model", 4000, 100, false, true, 0, 0, 110},
		{"unknown_prompt_proxy", 0, 100, false, false, 0, 0, 210},
		{"negative_prompt_proxy", -1, 100, false, false, 0, 0, 210},
		{"zero_incoming_uses_preflight_default", 4000, 0, false, false, 0, 0, 4510},
		{"negative_incoming_uses_preflight_default", 4000, -1, false, false, 0, 0, 4510},
		{"reflected_running_keeps_existing_proxy", 4000, 100, false, false, 1, 0, 113.9},
		{"reflected_waiting_keeps_existing_proxy", 4000, 100, false, false, 0, 1, 210},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resetCalibrator(t)
			reg := New(testLogger())
			model := "pending-boundary"
			p := calibrationTestProvider(t, reg, "pending-box", model, 100, 1000)
			pendingModel := model
			if tc.other {
				pendingModel = "another-model"
			}
			pr := &PendingRequest{RequestID: "ahead", Model: pendingModel, EstimatedPromptTokens: tc.prompt, RequestedMaxTokens: 1}
			if tc.committed {
				pr.MarkContentCommitted()
			}
			p.AddPending(pr)
			p.mu.Lock()
			p.BackendCapacity.Slots[0].NumRunning = tc.running
			p.BackendCapacity.Slots[0].NumWaiting = tc.waiting
			p.mu.Unlock()
			_, _, _, got, known := reg.QuickCapacityCheckWithTTFTForRequest(model, tc.incoming, 1, RequestTraits{}, false)
			if !known || math.Abs(float64(got.Microseconds())/1000-tc.want) > 0.001 {
				t.Fatalf("preflight=%v known=%v, want %.1fms", got, known, tc.want)
			}
		})
	}
}

func TestTTFTPendingPromptProxyAvoidsIntegerOverflow(t *testing.T) {
	snap := &routingSnapshot{backendWaiting: 2}
	prompt := int(^uint(0) >> 1)
	if got, want := queuedPrefillTokensAhead(snap, prompt), 2*float64(prompt); got != want {
		t.Fatalf("tokens=%v, want %v", got, want)
	}
}

func TestTTFTPendingPromptCacheWorkKeepsProxy(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	const model = "pending-cache"
	p := calibrationTestProvider(t, reg, "cache-box", model, 100, 1000)
	pr := &PendingRequest{RequestID: "cached-ahead", Model: model, EstimatedPromptTokens: 4000, RequestedMaxTokens: 1}
	pr.setCacheRoutingParticipates(true)
	p.AddPending(pr)
	_, _, _, got, known := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 1, RequestTraits{}, false)
	if !known || got.Milliseconds() != 210 {
		t.Fatalf("cache residual work unknown: estimate=%v known=%v, want unchanged 210ms proxy", got, known)
	}
}

// A lower internal-refusal count is insufficient: the scheduler must preserve
// a usable alternative instead of merely rejecting the incoming request.
func TestTTFTPendingPromptSelectsFeasibleAlternative(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	const model = "pending-alternative"
	busy := calibrationTestProvider(t, reg, "busy", model, 100, 1000)
	idle := calibrationTestProvider(t, reg, "idle", model, 1, 1000)
	busy.AddPending(&PendingRequest{RequestID: "long-ahead", Model: model, EstimatedPromptTokens: 4000, RequestedMaxTokens: 1})
	// The idle alternative's slow full decode makes it costlier, but it can
	// still emit first content inside the original 3s ceiling. Before the fix,
	// the busy provider won on cost with a fictional 210ms first-content estimate.
	pr := &PendingRequest{RequestID: "arriving", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, MaxTTFTMs: 3000}
	selected, d := reg.ReserveProviderEx(model, pr)
	if selected != idle || d.TTFTRejections != 1 || math.Abs(d.RawTTFTMs-1100) > 0.001 {
		t.Fatalf("selected provider=%q decision=%+v, want idle with 1100ms estimate and one TTFT rejection", d.ProviderID, d)
	}
	if pr.MaxTTFTMs != 3000 || busy.GetPending(pr.RequestID) != nil {
		t.Fatal("routing changed the deadline or reserved the rejected provider")
	}
}

func TestTTFTPendingPromptRevalidatesRetainedPlan(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	const model = "pending-plan"
	planTestProvider(t, reg, "primary", model, 0)
	alternate := planTestProvider(t, reg, "alternate", model, 400)
	pr := &PendingRequest{RequestID: "primary-request", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, MaxTTFTMs: 3000}
	selected, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if selected == nil || selected.ID != "primary" || plan == nil || plan.Len() != 1 {
		t.Fatal("expected primary reservation and one retained alternate")
	}
	alternate.AddPending(&PendingRequest{RequestID: "long-ahead", Model: model, EstimatedPromptTokens: 4000, RequestedMaxTokens: 1})
	retry := &PendingRequest{RequestID: "retry-request", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, MaxTTFTMs: 2900}
	got, _, skips := reg.ReserveNextFromPlan(retry, plan)
	if got != nil || len(skips) != 2 || skips[0].Reason != PlanSkipGateRejected || skips[1].Reason != PlanSkipExhausted {
		t.Fatalf("selected=%v skips=%+v, want updated prompt work rejected against decreasing budget", got != nil, skips)
	}
}

func TestTTFTPendingPromptSumsInputsAndRetiresCompletedWork(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	const model = "pending-sum"
	p := calibrationTestProvider(t, reg, "pending-box", model, 100, 1000)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1_000_000
	p.mu.Unlock()
	first := &PendingRequest{RequestID: "first", Model: model, EstimatedPromptTokens: 1000, RequestedMaxTokens: 50_000}
	second := &PendingRequest{RequestID: "second", Model: model, EstimatedPromptTokens: 3000, RequestedMaxTokens: 1}
	p.AddPending(first)
	p.AddPending(second)
	check := func(want int64) {
		t.Helper()
		_, _, _, got, known := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 1, RequestTraits{}, false)
		if !known || got.Milliseconds() != want {
			t.Fatalf("preflight=%v known=%v, want %dms", got, known, want)
		}
	}
	check(4110) // Heterogeneous prompts sum; 50,001 output tokens are not prefill.
	first.MarkContentCommitted()
	check(3110) // The still-running decoder no longer contributes prompt work.
	if p.GetPending(first.RequestID) != first {
		t.Fatal("first content must not retire its memory/output reservation")
	}
	p.RemovePending(second.RequestID)
	check(110)
}
