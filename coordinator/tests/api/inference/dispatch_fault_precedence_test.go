package inference_test

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	failurepolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestGenuineFaultTerminalPrecedenceIsAttemptOrderIndependent(t *testing.T) {
	tests := []struct {
		name                  string
		first                 protocol.InferenceErrorMessage
		second                protocol.InferenceErrorMessage
		wantCurrentCode       int
		wantCurrentDeadline   bool
		wantCurrentRouteClass string
	}{
		{
			name:                  "500 then deadline",
			first:                 genuineInternalFaultMessage(),
			second:                deadlineUnreachableMessage(),
			wantCurrentCode:       http.StatusServiceUnavailable,
			wantCurrentDeadline:   true,
			wantCurrentRouteClass: routeoutcome.ErrorClassDeadlineUnreachable,
		},
		{
			name:                  "deadline then 500",
			first:                 deadlineUnreachableMessage(),
			second:                genuineInternalFaultMessage(),
			wantCurrentCode:       http.StatusInternalServerError,
			wantCurrentDeadline:   false,
			wantCurrentRouteClass: "provider_error",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var ledger retry.TerminalEvidence
			latch := backend.NewLatch(nil)
			ledger.Observe(nil, "m", tc.first, 0, latch)
			current := ledger.Observe(nil, "m", tc.second, 0, latch)
			currentDeadline := failurepolicy.IsDeadlineUnreachableErrorReason(current.Message.ErrorReason)

			if current.Message.StatusCode != tc.wantCurrentCode ||
				currentDeadline != tc.wantCurrentDeadline {
				t.Fatalf(
					"current attempt = (code=%d, deadline=%v), want (%d, %v)",
					current.Message.StatusCode, currentDeadline,
					tc.wantCurrentCode, tc.wantCurrentDeadline)
			}
			currentOutcome := current.RouteOutcome(
				&registry.PendingRequest{RequestID: "current", Model: "m"})
			if currentOutcome.ErrorClass != tc.wantCurrentRouteClass {
				t.Fatalf(
					"current route class = %q, want %q",
					currentOutcome.ErrorClass, tc.wantCurrentRouteClass)
			}

			failure, sticky := ledger.Select(retry.NewTerminalFailure(current.Message, backend.Slot{}), false)
			status, reason, _, dominance := retry.ResolveTerminal(
				failure, sticky, retry.TerminalPolicy{})
			if !sticky || dominance != retry.GenuineFault {
				t.Fatalf(
					"terminal selection = (sticky=%v, dominance=%v), want genuine fault",
					sticky, dominance)
			}
			if status != http.StatusInternalServerError ||
				reason != "dispatch_exhausted" ||
				failure.ErrorText() != "provider internal error" {
				t.Fatalf(
					"terminal = (status=%d, reason=%q, error=%q), want genuine 500",
					status, reason, failure.ErrorText())
			}
		})
	}
}

func TestDeadlineOnlyExhaustionRemainsHealthNeutral429(t *testing.T) {
	var ledger retry.TerminalEvidence
	current := ledger.Observe(nil, "m", deadlineUnreachableMessage(), 0, backend.NewLatch(nil))

	failure, sticky := ledger.Select(retry.NewTerminalFailure(current.Message, backend.Slot{}), false)
	status, reason, _, dominance := retry.ResolveTerminal(
		failure, sticky, retry.TerminalPolicy{})
	if sticky {
		t.Fatal("deadline refusal was incorrectly promoted to genuine fault")
	}
	if status != http.StatusTooManyRequests ||
		reason != failurepolicy.ErrorReasonDeadlineUnreachable ||
		dominance != retry.Deadline {
		t.Fatalf(
			"deadline-only terminal = (%d, %q, %v), want health-neutral 429",
			status, reason, dominance)
	}
}
