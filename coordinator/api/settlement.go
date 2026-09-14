package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const defaultTerminalSettleGrace = settlement.DefaultGrace

// terminalSettleGrace returns the configured grace, defaulting when unset.
// Tests shrink it through s.settleGrace.
func (s *Server) terminalSettleGrace() time.Duration {
	if s.settleGrace > 0 {
		return s.settleGrace
	}
	return defaultTerminalSettleGrace
}

// holdForSettlement parks a mid-stream-disconnected request for late-terminal
// settlement, refunding its reservation if no terminal arrives within the grace.
func (s *Server) holdForSettlement(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	// Skip requests whose reservation was already settled/refunded before this
	// deferred park (e.g. a provider timeout or error that the relay already
	// refunded — Service.Refund finalizes but does not RemovePending, so the
	// cleanup still reaches here). Parking them would let a late provider terminal
	// see consumerGone and mislabel a timeout/error as an after-commit client
	// cancellation. A genuine after-commit client disconnect returns WITHOUT
	// refunding, so it is not yet finalized and is still parked + counted.
	if pr.IsReservationFinalized() {
		return
	}
	// Single chokepoint for post-commit consumer disconnects: the request
	// committed (streamed at least the first chunk) and the consumer-side handler
	// returned while a provider terminal was still outstanding. The after_commit
	// client-gone count is emitted at each terminal (handleComplete, handle-
	// InferenceError, and the grace-expiry path below) on routing.client_gone —
	// the single client-gone metric, with both phases plus prompt-size/chip
	// dimensions — so it is not duplicated here.
	if s.settlements == nil {
		// Defensive: a Server built without settlement.NewHolder still refunds
		// rather than leaking the reservation.
		if s.inferenceSettlement().Refund(pr, "no_terminal_after_cancel:"+pr.RequestID) {
			s.updateInferenceRouteOutcomeForPending(pr, noTerminalAfterCancelOutcome(pr))
			s.recordNoTerminalAfterCancel(pr.Model)
			s.emitClientGone(pr.Model, pr.EstimatedPromptTokens, "", phaseAfterCommit)
		}
		return
	}
	s.settlements.Hold(pr, s.terminalSettleGrace(), func(expired *registry.PendingRequest) {
		// Log only if this actually refunded — a request already settled by
		// handleComplete leaves a dup here whose refund no-ops (FinalizeReservation).
		if s.inferenceSettlement().Refund(expired, "no_terminal_after_cancel:"+expired.RequestID) {
			s.updateInferenceRouteOutcomeForPending(expired, noTerminalAfterCancelOutcome(expired))
			// Payout-gap edge: no provider terminal arrived within the grace, so the
			// reservation is refunded and the provider is never paid. Make it visible.
			s.recordNoTerminalAfterCancel(expired.Model)
			// After-commit client cancellation with no provider terminal: count it
			// on routing.client_gone too so the after_commit phase is complete
			// (provider-completed → handleComplete, provider-error →
			// handleInferenceError, no-terminal → here). The serving provider is
			// not in scope at grace expiry, so chip family is unknown.
			s.emitClientGone(expired.Model, expired.EstimatedPromptTokens, "", phaseAfterCommit)
			s.logger.Warn("no terminal from provider after cancel — refunded reservation",
				"request_id", expired.RequestID,
			)
		}
	})
}

// claimSettlement returns a parked billing record for requestID (consumed), or
// nil. Used by the terminal handlers when the request is no longer in the
// provider's pending set because the consumer already disconnected.
func (s *Server) claimSettlement(requestID string) *registry.PendingRequest {
	if s.settlements == nil {
		return nil
	}
	return s.settlements.Claim(requestID)
}
