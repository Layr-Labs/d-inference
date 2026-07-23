package api

// Typed terminal-cause health classification (the generation-deadline incident
// fix): the provider's flat safety deadline used to arrive as a generic 500,
// so the coordinator recorded a provider job failure and struck every health
// breaker for a PLATFORM policy ~178K times/week. These tests pin, for every
// value of the closed terminal_cause vocabulary (plus absent and unknown),
// exactly which failure recorders and breakers fire — through the REAL glue:
// handleInferenceError (reputation + load cooldown) and noteInferenceError
// (shape breaker, node-health breaker, stable-identity ejection, capacity
// cooldown), the same two funnels the incident report warns must be gated
// together.

import (
	"fmt"
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// deliverTypedError routes one full provider error terminal through both
// production funnels: handleInferenceError (provider read-loop side), then —
// exactly like the live relay/dispatch readers — the message echoed on ErrorCh
// is fed to noteInferenceError (consumer side).
func deliverTypedError(t *testing.T, srv *Server, provider *registry.Provider, model, requestID string, msg protocol.InferenceErrorMessage) *registry.PendingRequest {
	t.Helper()
	pr := &registry.PendingRequest{
		RequestID:  requestID,
		ProviderID: provider.ID,
		Model:      model,
		ChunkCh:    make(chan string, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	msg.Type = protocol.TypeInferenceError
	msg.RequestID = requestID
	srv.handleInferenceError(provider.ID, provider, &msg)
	em, ok := <-pr.ErrorCh
	if !ok {
		t.Fatalf("ErrorCh closed without a terminal for %s", requestID)
	}
	srv.noteInferenceError(pr.ProviderID, pr, em.StatusCode, em.Error, em.ErrorReason, em.TerminalCause)
	return pr
}

// TestTerminalCauseHealthClassification is the cause → funnel table. A plain
// sickness-shaped 500 body is used for every case so any behavior difference
// comes from the typed cause alone:
//
//	admission_timeout               → no fault anywhere; capacity cooldown strike
//	safety_deadline / backpressure_timeout / cancelled → fully neutral
//	prefill_stall / decode_stall / watchdog            → full fault (legacy funnels)
//	engine_error / absent / unknown                    → legacy behavior exactly
func TestTerminalCauseHealthClassification(t *testing.T) {
	cases := []struct {
		name  string
		cause string
		// wantJobFailures: registry.RecordJobFailure fired every round.
		wantJobFailures bool
		// wantFaultBreakers: shape-keyed inference-error cooldown, node-health
		// breaker, and stable-identity ejection all opened after the strikes.
		wantFaultBreakers bool
		// wantCapacityCooldown: the black-hole capacity cooldown tripped.
		wantCapacityCooldown bool
	}{
		{"admission_timeout", terminalCauseAdmissionTimeout, false, false, true},
		{"prefill_stall", terminalCausePrefillStall, true, true, false},
		{"decode_stall", terminalCauseDecodeStall, true, true, false},
		{"safety_deadline", terminalCauseSafetyDeadline, false, false, false},
		{"backpressure_timeout", terminalCauseBackpressureTimeout, false, false, false},
		{"watchdog", terminalCauseWatchdog, true, true, false},
		{"cancelled", terminalCauseCancelled, false, false, false},
		{"engine_error", terminalCauseEngineError, true, true, false},
		{"legacy_absent", "", true, true, false},
		{"unknown_drift_value", "lease_reaped", true, true, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, reg, provider, _ := newBreakerExemptionHarness(t, "cause-"+tc.name)
			model := "test-model"
			var lastPR *registry.PendingRequest
			// breakerStrikeRounds (10) comfortably exceeds every threshold:
			// shape cooldown 2, node breaker 5, ejection 8, capacity cooldown 5.
			for i := range breakerStrikeRounds {
				lastPR = deliverTypedError(t, srv, provider, model,
					fmt.Sprintf("req-%s-%d", tc.name, i), protocol.InferenceErrorMessage{
						Error:         "engine failure: generation aborted",
						StatusCode:    500,
						TerminalCause: tc.cause,
					})
			}

			provider.Mu().Lock()
			failed := provider.Reputation.FailedJobs
			provider.Mu().Unlock()
			wantFailed := 0
			if tc.wantJobFailures {
				wantFailed = breakerStrikeRounds
			}
			if failed != wantFailed {
				t.Errorf("Reputation.FailedJobs = %d, want %d", failed, wantFailed)
			}

			assertBreakerStates(t, reg, provider, lastPR, tc.wantFaultBreakers)

			if got := reg.CapacityCooldownActive(provider.ID, model); got != tc.wantCapacityCooldown {
				t.Errorf("capacity cooldown active = %v, want %v", got, tc.wantCapacityCooldown)
			}
		})
	}
}

// Neutral must mean NEUTRAL, not positive: a typed neutral terminal must not
// clear an already-open breaker or count as an accept/success. Trip the
// funnels with legacy faults first, then pour neutral terminals through and
// assert everything is still open.
func TestNeutralTerminalCauseDoesNotClearBreakers(t *testing.T) {
	srv, reg, provider, _ := newBreakerExemptionHarness(t, "neutral-no-clear")
	model := "test-model"

	// Open all three fault breakers with legacy (absent-cause) 500s.
	var lastPR *registry.PendingRequest
	for i := range breakerStrikeRounds {
		lastPR = deliverTypedError(t, srv, provider, model,
			fmt.Sprintf("req-open-%d", i), protocol.InferenceErrorMessage{
				Error:      "engine failure: generation aborted",
				StatusCode: 500,
			})
	}
	assertBreakerStates(t, reg, provider, lastPR, true)

	// Neutral terminals of every neutral flavor must leave them open.
	for i, cause := range []string{terminalCauseSafetyDeadline, terminalCauseBackpressureTimeout, terminalCauseCancelled} {
		lastPR = deliverTypedError(t, srv, provider, model,
			fmt.Sprintf("req-neutral-%d", i), protocol.InferenceErrorMessage{
				Error:         "request exceeded safety deadline",
				StatusCode:    504,
				TerminalCause: cause,
			})
	}
	assertBreakerStates(t, reg, provider, lastPR, true)

	// And the neutral terminals themselves recorded nothing new: reputation
	// failures stay at the legacy count.
	provider.Mu().Lock()
	failed := provider.Reputation.FailedJobs
	provider.Mu().Unlock()
	if failed != breakerStrikeRounds {
		t.Errorf("Reputation.FailedJobs = %d, want %d (neutral terminals must not add failures)", failed, breakerStrikeRounds)
	}
}

// A typed neutral cause must exempt even when the body/status carries the
// sickness shape AND when the legacy string heuristics would NOT exempt it —
// the cause wins over the strings in both funnels. Regression guard for
// "fixing only one funnel still falsely penalizes providers".
func TestSafetyDeadline500IsFullyNeutral(t *testing.T) {
	srv, reg, provider, _ := newBreakerExemptionHarness(t, "safety-500")
	model := "test-model"
	var lastPR *registry.PendingRequest
	for i := range breakerStrikeRounds {
		// 500 + fault-shaped text: legacy heuristics would strike everything.
		lastPR = deliverTypedError(t, srv, provider, model,
			fmt.Sprintf("req-safety-%d", i), protocol.InferenceErrorMessage{
				Error:         "generation error: request exceeded 120s deadline",
				StatusCode:    500,
				TerminalCause: terminalCauseSafetyDeadline,
			})
	}
	provider.Mu().Lock()
	failed := provider.Reputation.FailedJobs
	totalJobs := provider.Reputation.TotalJobs
	provider.Mu().Unlock()
	if failed != 0 || totalJobs != 0 {
		t.Errorf("FailedJobs/TotalJobs = %d/%d, want 0/0 (platform deadline is not a provider fault)", failed, totalJobs)
	}
	assertBreakerStates(t, reg, provider, lastPR, false)
	if reg.CapacityCooldownActive(provider.ID, model) {
		t.Error("safety_deadline must not feed the capacity cooldown either")
	}
}

// admission_timeout is a capacity signal with the black-hole safety semantics:
// strikes with zero interleaved accepts trip the capacity cooldown, but an
// accept resets the streak so a serving box can never trip.
func TestAdmissionTimeoutAcceptResetsCapacityStreak(t *testing.T) {
	srv, reg, provider, _ := newBreakerExemptionHarness(t, "admission-accept")
	model := "test-model"
	// Interleave: threshold is 5 strikes with zero interleaved accepts; an
	// accept after every 3 strikes must keep the pair un-cooled forever.
	for round := range 4 {
		for i := range 3 {
			deliverTypedError(t, srv, provider, model,
				fmt.Sprintf("req-adm-%d-%d", round, i), protocol.InferenceErrorMessage{
					Error:         "admission timeout: engine did not admit request",
					StatusCode:    503,
					TerminalCause: terminalCauseAdmissionTimeout,
				})
		}
		reg.RecordCapacityAccept(provider.ID, model)
	}
	if reg.CapacityCooldownActive(provider.ID, model) {
		t.Error("interleaved accepts must keep an admission-timing-out but serving pair out of the capacity cooldown")
	}
	// And admission timeouts never touched the fault side.
	provider.Mu().Lock()
	failed := provider.Reputation.FailedJobs
	provider.Mu().Unlock()
	if failed != 0 {
		t.Errorf("FailedJobs = %d, want 0", failed)
	}
}

// Legacy regression: with the cause ABSENT, the pre-existing string/status
// carve-outs still behave exactly as before (capacity strings and cancel
// terminals skip reputation; plain faults count). Mirrors
// TestHandleInferenceErrorReputationCarveout through the shared deliver glue
// so the new cause gate provably changed nothing for legacy frames.
func TestLegacyAbsentCauseKeepsExistingCarveouts(t *testing.T) {
	srv, _, provider, _ := newBreakerExemptionHarness(t, "legacy-carveout")
	model := "test-model"

	// Legacy capacity rejection (503) and cancel (499): no reputation failure.
	deliverTypedError(t, srv, provider, model, "req-legacy-503", protocol.InferenceErrorMessage{
		Error: "token_budget_exhausted", StatusCode: 503,
	})
	deliverTypedError(t, srv, provider, model, "req-legacy-499", protocol.InferenceErrorMessage{
		Error: "request cancelled by consumer", StatusCode: 499,
	})
	provider.Mu().Lock()
	failed := provider.Reputation.FailedJobs
	provider.Mu().Unlock()
	if failed != 0 {
		t.Fatalf("legacy capacity/cancel terminals: FailedJobs = %d, want 0", failed)
	}

	// Legacy plain fault: reputation failure recorded.
	deliverTypedError(t, srv, provider, model, "req-legacy-500", protocol.InferenceErrorMessage{
		Error: "model crashed during generation", StatusCode: 500,
	})
	provider.Mu().Lock()
	failed = provider.Reputation.FailedJobs
	provider.Mu().Unlock()
	if failed != 1 {
		t.Fatalf("legacy plain 500: FailedJobs = %d, want 1", failed)
	}
}

// classifyTerminalCause unit table: every vocabulary value maps to its class
// and only out-of-vocabulary values report unknown.
func TestClassifyTerminalCause(t *testing.T) {
	cases := []struct {
		cause     string
		wantClass terminalCauseClass
		wantKnown bool
	}{
		{"", causeClassLegacy, true},
		{terminalCauseAdmissionTimeout, causeClassCapacity, true},
		{terminalCausePrefillStall, causeClassFault, true},
		{terminalCauseDecodeStall, causeClassFault, true},
		{terminalCauseSafetyDeadline, causeClassNeutral, true},
		{terminalCauseBackpressureTimeout, causeClassNeutral, true},
		{terminalCauseWatchdog, causeClassFault, true},
		{terminalCauseCancelled, causeClassNeutral, true},
		{terminalCauseEngineError, causeClassLegacy, true},
		{"lease_reaped", causeClassLegacy, false},
		{"SAFETY_DEADLINE", causeClassLegacy, false}, // vocabulary is exact-match
	}
	for _, tc := range cases {
		class, known := classifyTerminalCause(tc.cause)
		if class != tc.wantClass || known != tc.wantKnown {
			t.Errorf("classifyTerminalCause(%q) = (%v, %v), want (%v, %v)",
				tc.cause, class, known, tc.wantClass, tc.wantKnown)
		}
	}
}

// Typed terminal metrics: a known cause emits inference.typed_terminal tagged
// with the cause; an unknown value emits the vocabulary-drift counter and is
// tagged cause:unknown; a legacy frame emits neither.
func TestTypedTerminalMetrics(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	provider := reg.Register("provider-typed-metrics", nil, &protocol.RegisterMessage{
		Type:   protocol.TypeRegister,
		Models: []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
	})

	deliverTypedError(t, srv, provider, "test-model", "req-metric-typed", protocol.InferenceErrorMessage{
		Error: "deadline", StatusCode: 504, TerminalCause: terminalCauseSafetyDeadline,
	})
	deliverTypedError(t, srv, provider, "test-model", "req-metric-unknown", protocol.InferenceErrorMessage{
		Error: "??", StatusCode: 500, TerminalCause: "lease_reaped",
	})
	deliverTypedError(t, srv, provider, "test-model", "req-metric-legacy", protocol.InferenceErrorMessage{
		Error: "boom", StatusCode: 500,
	})

	_ = dd.Statsd.Flush()
	packets := collector.drain()

	typed := findMetrics(packets, metricTypedTerminal+":")
	if len(typed) != 2 {
		t.Fatalf("typed_terminal packets = %d (%v), want 2 (typed + unknown; legacy emits none)", len(typed), typed)
	}
	if !hasMetric(typed, "cause:"+terminalCauseSafetyDeadline) {
		t.Errorf("missing cause:safety_deadline tag in %v", typed)
	}
	if !hasMetric(typed, "cause:unknown") {
		t.Errorf("unknown vocabulary value must be tagged cause:unknown, got %v", typed)
	}
	if hasMetric(typed, "cause:lease_reaped") {
		t.Errorf("raw drift value must never become a tag, got %v", typed)
	}
	if drift := findMetrics(packets, metricUnknownTerminalCause+":"); len(drift) != 1 {
		t.Errorf("unknown-cause drift counter packets = %d (%v), want 1", len(drift), drift)
	}
}
