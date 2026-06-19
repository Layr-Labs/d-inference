package api

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// defaultTerminalSettleGrace bounds how long a disconnected request's billing
// record waits for the provider's terminal before its reservation is refunded.
// A connected provider aborts within ms; 30s is a wide WS-latency margin. The
// record lives outside the provider's pending set, so it doesn't count against
// concurrency/idle while waiting.
const defaultTerminalSettleGrace = 30 * time.Second

// settlementHolder parks the billing record of a consumer-disconnected request
// so a late provider terminal can settle it (charge delivered tokens) instead of
// hitting "unknown request" — which would leak the reservation and pay $0. No
// terminal within the grace → refund. Claim is single-winner (terminal handler
// vs. grace timer); FinalizeReservation independently guards double-counting.
type settlementHolder struct {
	mu      sync.Mutex
	pending map[string]*registry.PendingRequest
}

func newSettlementHolder() *settlementHolder {
	return &settlementHolder{pending: make(map[string]*registry.PendingRequest)}
}

// hold stores pr under its request id and schedules onExpiry(pr) after grace if
// it has not been claimed by then. onExpiry runs at most once for a held record.
func (h *settlementHolder) hold(pr *registry.PendingRequest, grace time.Duration, onExpiry func(*registry.PendingRequest)) {
	if pr == nil {
		return
	}
	h.mu.Lock()
	h.pending[pr.RequestID] = pr
	h.mu.Unlock()

	time.AfterFunc(grace, func() {
		if expired := h.claim(pr.RequestID); expired != nil {
			onExpiry(expired)
		}
	})
}

// claim removes and returns the held record for requestID, or nil if none
// (already claimed, expired, or never held).
func (h *settlementHolder) claim(requestID string) *registry.PendingRequest {
	h.mu.Lock()
	defer h.mu.Unlock()
	pr, ok := h.pending[requestID]
	if !ok {
		return nil
	}
	delete(h.pending, requestID)
	return pr
}

// terminalSettleGrace returns the configured grace, defaulting when unset
// (tests shrink it via s.settleGrace).
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
	// refunded — refundReservedBalance finalizes but does not RemovePending, so the
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
		// Defensive: a Server built without newSettlementHolder still refunds
		// rather than leaking the reservation.
		if s.refundReservedBalance(pr, "no_terminal_after_cancel:"+pr.RequestID) {
			s.updateInferenceRouteOutcomeForPending(pr, noTerminalAfterCancelOutcome(pr))
			s.recordNoTerminalAfterCancel(pr.Model)
			s.emitClientGone(pr.Model, pr.EstimatedPromptTokens, "", phaseAfterCommit)
		}
		return
	}
	s.settlements.hold(pr, s.terminalSettleGrace(), func(expired *registry.PendingRequest) {
		// Log only if this actually refunded — a request already settled by
		// handleComplete leaves a dup here whose refund no-ops (FinalizeReservation).
		if s.refundReservedBalance(expired, "no_terminal_after_cancel:"+expired.RequestID) {
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
	return s.settlements.claim(requestID)
}
