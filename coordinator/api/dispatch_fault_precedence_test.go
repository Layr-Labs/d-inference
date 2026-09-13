package api

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func genuineInternalFaultMessage() protocol.InferenceErrorMessage {
	return protocol.InferenceErrorMessage{
		RequestID:   "fault-request",
		Error:       "backend exploded",
		StatusCode:  http.StatusInternalServerError,
		FailureCode: protocol.FailureCodeInternalFailure,
	}
}

func deadlineUnreachableMessage() protocol.InferenceErrorMessage {
	return protocol.InferenceErrorMessage{
		RequestID:   "deadline-request",
		Error:       "remaining deadline cannot be met",
		StatusCode:  http.StatusServiceUnavailable,
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: errorReasonDeadlineUnreachable,
	}
}

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
			wantCurrentRouteClass: errorClassDeadlineUnreachable,
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
			d := &dispatchState{
				s:     newTestServerForDispatch(t),
				model: "m",
			}
			d.setLastInferenceError(nil, tc.first)
			d.setLastInferenceError(nil, tc.second)

			if d.lastErrCode != tc.wantCurrentCode ||
				d.lastFailureDeadline != tc.wantCurrentDeadline {
				t.Fatalf(
					"current attempt = (code=%d, deadline=%v), want (%d, %v)",
					d.lastErrCode, d.lastFailureDeadline,
					tc.wantCurrentCode, tc.wantCurrentDeadline)
			}
			currentOutcome := d.providerFailedRoutingOutcomeFor(
				&registry.PendingRequest{RequestID: "current", Model: "m"})
			if currentOutcome.ErrorClass != tc.wantCurrentRouteClass {
				t.Fatalf(
					"current route class = %q, want %q",
					currentOutcome.ErrorClass, tc.wantCurrentRouteClass)
			}

			failure, sticky := d.terminalFailureForExhaustion()
			status, reason, _, dominance := d.resolveDominantExhaustedStatus(
				failure, sticky)
			if !sticky || dominance != exhaustedGenuineFault {
				t.Fatalf(
					"terminal selection = (sticky=%v, dominance=%v), want genuine fault",
					sticky, dominance)
			}
			if status != http.StatusInternalServerError ||
				reason != "dispatch_exhausted" ||
				failure.errText != "provider internal error" {
				t.Fatalf(
					"terminal = (status=%d, reason=%q, error=%q), want genuine 500",
					status, reason, failure.errText)
			}
		})
	}
}

func TestDeadlineOnlyExhaustionRemainsHealthNeutral429(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.setLastInferenceError(nil, deadlineUnreachableMessage())

	failure, sticky := d.terminalFailureForExhaustion()
	status, reason, _, dominance := d.resolveDominantExhaustedStatus(
		failure, sticky)
	if sticky {
		t.Fatal("deadline refusal was incorrectly promoted to genuine fault")
	}
	if status != http.StatusTooManyRequests ||
		reason != rejectionReasonDeadlineUnreachable ||
		dominance != exhaustedDeadline {
		t.Fatalf(
			"deadline-only terminal = (%d, %q, %v), want health-neutral 429",
			status, reason, dominance)
	}
}

func TestGenuineFaultClassificationExcludesNeutralAndDeterministicFailures(t *testing.T) {
	tests := []struct {
		name string
		msg  protocol.InferenceErrorMessage
		want bool
	}{
		{"internal failure", genuineInternalFaultMessage(), true},
		{"generation failure", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeGenerationFailure,
		}, true},
		{"capacity refusal", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeCapacity,
		}, false},
		{"model unavailable", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeModelUnavailable,
		}, false},
		{"deterministic client failure", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeInvalidRequest,
		}, false},
		{"template render failure", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeTemplateRender,
		}, false},
		{"tool noncompliance", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeGenerationFailure,
			ErrorReason: errorReasonToolNoncompliance,
		}, false},
		{"deadline unreachable", deadlineUnreachableMessage(), false},
		{"admission timeout", protocol.InferenceErrorMessage{
			StatusCode:    http.StatusServiceUnavailable,
			FailureCode:   protocol.FailureCodeCapacity,
			TerminalCause: terminalCauseAdmissionTimeout,
		}, false},
		{"neutral safety deadline", protocol.InferenceErrorMessage{
			StatusCode:    http.StatusGatewayTimeout,
			FailureCode:   protocol.FailureCodeGenerationFailure,
			TerminalCause: terminalCauseSafetyDeadline,
		}, false},
		{"typed watchdog fault", protocol.InferenceErrorMessage{
			StatusCode:    http.StatusInternalServerError,
			FailureCode:   protocol.FailureCodeGenerationFailure,
			TerminalCause: terminalCauseWatchdog,
		}, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			msg := normalizeInferenceErrorForInternalUse(tc.msg)
			if got := isGenuinePreContentFault(msg, 0, 0); got != tc.want {
				t.Fatalf("isGenuinePreContentFault() = %v, want %v; msg=%+v", got, tc.want, msg)
			}
		})
	}
}
