package inference

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (d *dispatchState) primaryRequest() PrimaryRequest {
	_, sticky := d.terminalEvidence.Select(d.currentTerminalFailure(), false)
	return PrimaryRequest{
		Dispatch: d.dispatchInput(d.timing, d.excludeProviders, "", nil),
		Metadata: dispatch.PendingMetadata{Endpoint: d.consumerEndpoint, StopSequences: d.requestedStopSequences, Details: d.metadataDetails},
		Writer:   d.w, Refund: d.refundReservation, RequestID: d.requestID, Stream: d.stream,
		SpeculativeAt: d.speculativeAt, VisionImageCount: d.visionImageCount, PredictiveRefusals: d.predictiveRefusals,
		AttributionFrozen: sticky || d.unservable || d.terminalClientError, StickyFault: sticky,
		History: PrimaryHistory{
			Failure: retry.AttemptFailure{Message: protocol.InferenceErrorMessage{
				Error: d.lastErr, StatusCode: d.lastErrCode, ErrorReason: d.lastErrReason,
				TerminalCause: d.lastErrTerminalCause, CoordinatorCause: d.lastErrCoordinatorCause,
				RejectionReason: d.lastErrRejectionReason, AttemptUsage: d.lastErrAttemptUsage,
				FeasibleAfterMS: d.lastErrFeasibleAfterMS,
			}, ProviderBudget: d.lastErrProviderBudget},
			DeadlineFailure: d.lastFailureDeadline,
			Terminal: PrimaryTerminal{UnservableReason: d.unservableReason,
				ClientStatus: d.terminalClientErrorCode, ClientReason: d.terminalClientErrorReason, ClientMessage: d.terminalClientErrorMessage},
			Overflow: ProviderBodyOverflow{Message: d.providerBodyTooLargeErr, Bytes: d.providerBodyTooLargeBytes},
		},
	}
}

// The loop and its exhaustion ladder consume the returned evidence directly;
// Primary keeps no second copy of request history after an attempt returns.
func (d *dispatchState) applyPrimaryResult(result PrimaryResult) {
	d.provider, d.pr, d.requestID = result.Provider, result.Pending, result.RequestID
	d.dispatchErr, d.dispatchErrCode = result.DispatchError, result.DispatchCode
	msg := result.History.Failure.Message
	d.lastErr, d.lastErrCode, d.lastErrReason = msg.Error, msg.StatusCode, msg.ErrorReason
	d.lastErrTerminalCause, d.lastErrCoordinatorCause = msg.TerminalCause, msg.CoordinatorCause
	d.lastErrRejectionReason, d.lastErrAttemptUsage = msg.RejectionReason, msg.AttemptUsage
	d.lastErrFeasibleAfterMS, d.lastErrProviderBudget = msg.FeasibleAfterMS, result.History.Failure.ProviderBudget
	d.lastFailureDeadline = result.History.DeadlineFailure
	d.unservableReason = result.History.Terminal.UnservableReason
	if d.unservableReason != "" {
		d.unservable = true
	}
	d.terminalClientErrorCode = result.History.Terminal.ClientStatus
	d.terminalClientErrorReason, d.terminalClientErrorMessage = result.History.Terminal.ClientReason, result.History.Terminal.ClientMessage
	if d.terminalClientErrorCode != 0 {
		d.terminalClientError = true
	}
	d.providerBodyTooLargeErr, d.providerBodyTooLargeBytes = result.History.Overflow.Message, result.History.Overflow.Bytes
	if result.HedgeAdvance != nil {
		d.hedgeAdvanceCh = result.HedgeAdvance
	}
}
