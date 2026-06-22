package registry

import "testing"

// withTTFTConfig snapshots and restores the package-level Phase-0 TTFT knobs so
// each test runs in isolation (Go runs package tests sequentially, so resetting
// in Cleanup is sufficient).
func withTTFTConfig(t *testing.T, alpha, deadlineBaseMs float64, mode TTFTAdmissionMode) {
	t.Helper()
	prevAlpha := TTFTOccupancyAlpha()
	prevBase := TTFTDeadlineBaseMs()
	prevMode := TTFTAdmissionModeValue()
	t.Cleanup(func() {
		SetTTFTOccupancyAlpha(prevAlpha)
		SetTTFTDeadlineBaseMs(prevBase)
		SetTTFTAdmissionMode(prevMode)
	})
	SetTTFTOccupancyAlpha(alpha)
	if deadlineBaseMs > 0 {
		SetTTFTDeadlineBaseMs(deadlineBaseMs)
	}
	SetTTFTAdmissionMode(mode)
}

// TestTTFTOccupancyTermZeroWhenAlphaZero pins the behavior-neutral default: with
// alpha=0 the occupancy term contributes nothing, so ttftMsFromSnapshot is
// byte-for-byte the pre-Phase-0 estimate no matter how herded the box is.
func TestTTFTOccupancyTermZeroWhenAlphaZero(t *testing.T) {
	if TTFTOccupancyAlpha() != 0 {
		t.Fatalf("default occupancy alpha must be 0, got %f", TTFTOccupancyAlpha())
	}
	snap := routingSnapshot{
		hasBackendCapacity: true,
		slotState:          "running",
		decodeTPS:          55,
		prefillTPS:         660,
		backendRunning:     8,
		pendingForModel:    8,
	}
	if got := ttftOccupancyMs(snap); got != 0 {
		t.Fatalf("ttftOccupancyMs must be 0 when alpha=0, got %f", got)
	}
}

// TestTTFTEstimateOccupancyTermActiveAndMonotonic exercises the flag ON: the
// occupancy term raises the estimate, the estimate is strictly increasing in
// occupancy, and it crosses the verified ~10s deadline at a knee.
func TestTTFTEstimateOccupancyTermActiveAndMonotonic(t *testing.T) {
	withTTFTConfig(t, 45, defaultTTFTDeadlineBaseMs, TTFTAdmissionOff)

	mk := func(running int) routingSnapshot {
		return routingSnapshot{
			hasBackendCapacity: true,
			slotState:          "running",
			decodeTPS:          55, // gpt-oss solo ~55 tok/s
			prefillTPS:         660,
			backendRunning:     running,
		}
	}
	const reqPrompt = 1000

	// The occupancy term must add to the estimate at b>0 (compare alpha on vs off).
	SetTTFTOccupancyAlpha(0)
	base4 := ttftMsFromSnapshot(mk(4), reqPrompt)
	SetTTFTOccupancyAlpha(45)
	withTerm4 := ttftMsFromSnapshot(mk(4), reqPrompt)
	if withTerm4 <= base4 {
		t.Fatalf("occupancy term must raise the estimate at b=4: with=%f base=%f", withTerm4, base4)
	}

	// Strictly increasing in occupancy, crossing the deadline at a knee.
	deadline := ttftDeadlineMsForPrompt(reqPrompt)
	last := -1.0
	knee := -1
	for b := 0; b <= 8; b++ {
		est := ttftMsFromSnapshot(mk(b), reqPrompt)
		if est <= last {
			t.Fatalf("estimate not strictly increasing at b=%d: %f <= %f", b, est, last)
		}
		last = est
		if knee < 0 && est > deadline {
			knee = b
		}
	}
	if knee < 1 || knee > 8 {
		t.Fatalf("estimate should cross the %.0fms deadline at a knee in b=1..8, got knee=%d", deadline, knee)
	}
	// b=0 (idle) must stay well under the deadline — route-to-idle is preserved.
	if idle := ttftMsFromSnapshot(mk(0), reqPrompt); idle > deadline {
		t.Fatalf("idle box (b=0) must be under the deadline, got %f > %f", idle, deadline)
	}
}

func TestParseTTFTAdmissionMode(t *testing.T) {
	cases := map[string]TTFTAdmissionMode{
		"":        TTFTAdmissionOff,
		"off":     TTFTAdmissionOff,
		"garbage": TTFTAdmissionOff,
		"shadow":  TTFTAdmissionShadow,
		" SHADOW": TTFTAdmissionShadow,
		"enforce": TTFTAdmissionEnforce,
	}
	for in, want := range cases {
		if got := ParseTTFTAdmissionMode(in); got != want {
			t.Errorf("ParseTTFTAdmissionMode(%q) = %v, want %v", in, got, want)
		}
	}
}

// TestTTFTAdmissionModeOffNoShadowEval confirms the default mode leaves the
// RoutingDecision shadow fields untouched (behavior-neutral observability).
func TestTTFTAdmissionModeOffNoShadowEval(t *testing.T) {
	withTTFTConfig(t, 45, defaultTTFTDeadlineBaseMs, TTFTAdmissionOff)
	reg := New(testLogger())
	model := "shadow-off-model"
	makeSchedulerProvider(t, reg, "p1", model, 100)

	_, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "r1", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	if decision.ShadowEvaluated {
		t.Fatalf("admission mode off must not evaluate shadow: %+v", decision)
	}
	if decision.ShadowMode != "" || decision.ShadowWouldShed || decision.ShadowIdleAlternativeExists {
		t.Fatalf("shadow fields must be zero when off: %+v", decision)
	}
}

// TestTTFTShadowEvalWouldShedButStillServes is the core shadow assertion: a
// herded provider whose occupancy-aware estimate exceeds the ~10s base is flagged
// would_shed, yet the request is STILL served (the decision is unchanged). This
// is the behavior-neutral guarantee of shadow mode.
func TestTTFTShadowEvalWouldShedButStillServes(t *testing.T) {
	withTTFTConfig(t, 45, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-shed-model"
	p := makeSchedulerProvider(t, reg, "busy", model, 55)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].NumRunning = 6 // herded → occupancy-aware estimate >> 10s
	p.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "r1", Model: model, EstimatedPromptTokens: 1000, RequestedMaxTokens: 256})
	if selected == nil || decision.ProviderID != p.ID {
		t.Fatalf("shadow mode must NOT change the decision — provider should still be served: selected=%v decision=%+v", selected, decision)
	}
	if !decision.ShadowEvaluated || decision.ShadowMode != "shadow" {
		t.Fatalf("shadow eval should be populated: %+v", decision)
	}
	if !decision.ShadowWouldShed {
		t.Fatalf("a b=6 gpt-oss box at alpha=45 should be flagged would_shed (est=%f deadline=%f)", decision.ShadowEstimateMs, decision.ShadowDeadlineMs)
	}
	if decision.ShadowEstimateMs <= decision.ShadowDeadlineMs {
		t.Fatalf("would_shed implies estimate>deadline: est=%f deadline=%f", decision.ShadowEstimateMs, decision.ShadowDeadlineMs)
	}
}

// TestTTFTShadowEvalRedirectToIdle reproduces the load-spreading failure the data
// shows: the cost lands a request on a fast-but-herded box while an
// instantly-usable loaded-idle box for the same model was routable. Shadow flags
// would_redirect_to_idle=true without changing the (herded) selection.
func TestTTFTShadowEvalRedirectToIdle(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-spread-model"

	// Fast but herded winner: occupancy=1, but so cheap it still beats the slow
	// idle box on cost.
	fastBusy := makeSchedulerProvider(t, reg, "fast-busy", model, 300)
	fastBusy.mu.Lock()
	fastBusy.BackendCapacity.Slots[0].NumRunning = 1
	fastBusy.mu.Unlock()

	// Slow, idle, loaded alternative (occupancy=0).
	makeSchedulerProvider(t, reg, "slow-idle", model, 20)

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "r1", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 256})
	if selected == nil {
		t.Fatalf("expected a selection, got nil: %+v", decision)
	}
	if selected.ID != fastBusy.ID {
		t.Skipf("cost model did not pick the herded box (picked %q); spread-signal precondition not met", selected.ID)
	}
	if !decision.ShadowEvaluated {
		t.Fatalf("shadow eval should be populated: %+v", decision)
	}
	if decision.ShadowOccupancy == 0 {
		t.Fatalf("winner should be herded (occupancy>0): %+v", decision)
	}
	if !decision.ShadowIdleAlternativeExists {
		t.Fatalf("an idle loaded alternative existed; would_redirect_to_idle must be true: %+v", decision)
	}
}

// TestTTFTShadowEvalNoRedirectWhenWinnerIdle confirms the spread signal is false
// when the request already landed on an idle box (nothing better to spread to).
func TestTTFTShadowEvalNoRedirectWhenWinnerIdle(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-idle-winner-model"
	makeSchedulerProvider(t, reg, "idle", model, 100)

	_, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "r1", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	if !decision.ShadowEvaluated {
		t.Fatalf("shadow eval should be populated: %+v", decision)
	}
	if decision.ShadowOccupancy != 0 {
		t.Fatalf("winner should be idle (occupancy 0): %+v", decision)
	}
	if decision.ShadowIdleAlternativeExists {
		t.Fatalf("no redirect signal expected when the winner itself is idle: %+v", decision)
	}
}
