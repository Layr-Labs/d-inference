package inference

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (d *dispatchState) retryController() *retry.Controller {
	if d.retryPolicy == nil {
		d.retryPolicy = retry.New(retry.Config{Model: d.model, ModelContext: d.modelMaxContext,
			DisableClientErrorStop: d.s.disableClientErrorStop, Observation: d.s.observation})
	}
	return d.retryPolicy
}

func (d *dispatchState) applyRetryDecision(result retry.Decision) {
	d.capacityRetries, d.firstChunkTimeoutRetries = result.CapacityRetries, result.TimeoutRetries
	if result.ClientStatusCode != 0 {
		d.terminalClientError = true
		d.terminalClientErrorCode, d.terminalClientErrorReason, d.terminalClientErrorMessage = result.ClientStatusCode, result.ClientReason, result.ClientMessage
	}
	if result.UnservableReason != "" {
		d.unservable, d.unservableReason = true, result.UnservableReason
	}
	if result.DeadlineUnreachable {
		d.lastFailureDeadline = true
	}
}

func (d *dispatchState) retryDecision() retry.Decision {
	if d.unservable || d.terminalClientError {
		return retry.Decision{Stop: true,
			ClientStatusCode: d.terminalClientErrorCode, ClientReason: d.terminalClientErrorReason,
			ClientMessage: d.terminalClientErrorMessage, UnservableReason: d.unservableReason,
			CapacityRetries: d.capacityRetries, TimeoutRetries: d.firstChunkTimeoutRetries,
		}
	}
	result := d.retryController().Decide(protocol.InferenceErrorMessage{
		Error: d.lastErr, StatusCode: d.lastErrCode, ErrorReason: d.lastErrReason,
		TerminalCause: d.lastErrTerminalCause, RejectionReason: d.lastErrRejectionReason,
	}, d.lastErrProviderBudget)
	d.applyRetryDecision(result)
	return result
}
