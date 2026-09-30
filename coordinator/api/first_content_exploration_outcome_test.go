package api

// Exploration outcome hooks (registry/first_content_exploration_gate.go): an
// attempt selected through evidence exploration feeds its result back so a
// provider whose explorations fail is not explored again at once. These pin
// which terminals count, through the real noteInferenceError glue, and that
// a non-explored attempt never touches the exploration state.

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func deliverExploredError(t *testing.T, srv *Server, provider *registry.Provider, model, requestID string, explored bool, msg protocol.InferenceErrorMessage) {
	t.Helper()
	pr := &registry.PendingRequest{
		RequestID:  requestID,
		ProviderID: provider.ID,
		Model:      model,
		ChunkCh:    make(chan registry.ProviderChunk, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	pr.SetFirstContentExplored(explored)
	provider.AddPending(pr)
	msg.Type = protocol.TypeInferenceError
	msg.RequestID = requestID
	srv.handleInferenceError(provider.ID, provider, &msg)
	em, ok := <-pr.ErrorCh
	if !ok {
		t.Fatalf("ErrorCh closed without a terminal for %s", requestID)
	}
	srv.noteInferenceError(pr.ProviderID, pr, em.StatusCode, em.Error, em.ErrorReason, em.TerminalCause, em.CoordinatorCause)
}

func TestFirstContentExplorationOutcomeClassification(t *testing.T) {
	cases := []struct {
		name           string
		explored       bool
		msg            protocol.InferenceErrorMessage
		wantSuppressed bool
	}{
		{"deadline_refusal_explored", true, protocol.InferenceErrorMessage{
			Error: "deadline unreachable", StatusCode: 503, ErrorReason: errorReasonDeadlineUnreachable,
			FailureCode: protocol.FailureCodeCapacity}, true},
		{"deadline_refusal_not_explored", false, protocol.InferenceErrorMessage{
			Error: "deadline unreachable", StatusCode: 503, ErrorReason: errorReasonDeadlineUnreachable,
			FailureCode: protocol.FailureCodeCapacity}, false},
		{"genuine_fault_explored", true, protocol.InferenceErrorMessage{
			Error: "engine failure: generation aborted", StatusCode: 500,
			FailureCode: protocol.FailureCodeGenerationFailure}, true},
		{"neutral_terminal_explored", true, protocol.InferenceErrorMessage{
			Error: "deadline", StatusCode: 504, TerminalCause: terminalCauseSafetyDeadline,
			FailureCode: protocol.FailureCodeGenerationFailure}, false},
		// A capacity shed never ran the request: neutral for exploration as
		// it is for the node-health breaker.
		{"capacity_shed_explored", true, protocol.InferenceErrorMessage{
			Error: "token budget exceeded", StatusCode: 503, FailureCode: protocol.FailureCodeCapacity}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, reg, provider, _ := newBreakerExemptionHarness(t, "explore-"+tc.name)
			deliverExploredError(t, srv, provider, "test-model", fmt.Sprintf("req-%s", tc.name), tc.explored, tc.msg)
			if got := reg.FirstContentExplorationSuppressed(provider.ID, "test-model"); got != tc.wantSuppressed {
				t.Fatalf("exploration suppressed=%v, want %v", got, tc.wantSuppressed)
			}
		})
	}
}

// A deadline refusal on an explored attempt backs exploration off without
// striking any health breaker: the maintainers' health-neutral rule stands.
func TestFirstContentExplorationDeadlineRefusalStaysHealthNeutral(t *testing.T) {
	srv, reg, provider, _ := newBreakerExemptionHarness(t, "explore-neutral")
	for i := range breakerStrikeRounds {
		deliverExploredError(t, srv, provider, "test-model", fmt.Sprintf("req-neutral-%d", i), true,
			protocol.InferenceErrorMessage{Error: "deadline unreachable", StatusCode: 503,
				ErrorReason: errorReasonDeadlineUnreachable, FailureCode: protocol.FailureCodeCapacity})
	}
	if !reg.FirstContentExplorationSuppressed(provider.ID, "test-model") {
		t.Fatal("explored deadline refusals did not back exploration off")
	}
	if reg.ProviderBreakerOpen(provider.ID) {
		t.Fatal("deadline refusals opened the node-health breaker")
	}
}

// The dominant failure of the provider that motivated this: explored
// attempts cancelled for a first-content timeout, which no breaker sees.
func TestFirstContentExplorationFirstContentTimeoutBacksOff(t *testing.T) {
	for _, explored := range []bool{false, true} {
		t.Run(fmt.Sprintf("explored_%v", explored), func(t *testing.T) {
			srv, reg, provider, _ := newBreakerExemptionHarness(t, fmt.Sprintf("explore-timeout-%v", explored))
			pr := &registry.PendingRequest{RequestID: "req-timeout", ProviderID: provider.ID, Model: "test-model",
				ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
				ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
			pr.SetFirstContentExplored(explored)
			provider.AddPending(pr)
			if !srv.cancelDispatchForFirstContentTimeout(provider, pr) {
				t.Fatal("setup: the timeout did not own the cancellation")
			}
			if got := reg.FirstContentExplorationSuppressed(provider.ID, "test-model"); got != explored {
				t.Fatalf("exploration suppressed=%v, want %v", got, explored)
			}
			if reg.ProviderBreakerOpen(provider.ID) {
				t.Fatal("a first-content timeout opened the node-health breaker")
			}
		})
	}
}

// A delivered exploration halves the backoff; after one failure that clears it.
func TestFirstContentExplorationSuccessRecovers(t *testing.T) {
	srv, reg, provider, _ := newBreakerExemptionHarness(t, "explore-success")
	reg.RecordFirstContentExplorationOutcome(provider.ID, "test-model", false)
	if !reg.FirstContentExplorationSuppressed(provider.ID, "test-model") {
		t.Fatal("setup: failure did not suppress exploration")
	}
	pr := &registry.PendingRequest{RequestID: "req-ok", ProviderID: provider.ID, Model: "test-model"}
	pr.SetFirstContentExplored(true)
	srv.noteInferenceSuccess(pr)
	if reg.FirstContentExplorationSuppressed(provider.ID, "test-model") {
		t.Fatal("a delivered exploration did not lift a one-failure backoff")
	}
}
