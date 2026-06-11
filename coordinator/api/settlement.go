package api

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// defaultTerminalSettleGrace is how long a mid-stream-disconnected request's
// billing record is held, waiting for the provider's terminal
// inference_complete/_error to settle it, before the reservation is refunded.
//
// A connected provider aborts and emits its terminal within milliseconds of the
// cancel; 30s covers WS latency with a wide margin. The record lives OUTSIDE the
// provider's pending set (registry pendingReqs), so it never counts against the
// provider's concurrency headroom or idle state during the wait — the slot frees
// immediately on disconnect, only the billing tail lingers.
const defaultTerminalSettleGrace = 30 * time.Second

// settlementHolder parks the billing context of a request whose consumer
// disconnected mid-stream so a late provider terminal can still settle it
// (charge for delivered tokens) instead of hitting "complete for unknown
// request" — which would leak the consumer's reservation and pay the provider
// nothing for real work. If no terminal arrives within the grace, the reservation
// is refunded. Claim is single-winner: whichever of the terminal handler or the
// grace timer claims first gets the record; the other sees nil. Reservation
// finalization is independently idempotent (FinalizeReservation), so a settle/
// refund race cannot double-count.
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

// terminalSettleGrace returns the configured grace, defaulting when unset (so
// tests can shrink it via the Server field without every caller threading it).
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
	if s.settlements == nil {
		// Defensive: a Server built without newSettlementHolder still refunds
		// rather than leaking the reservation.
		s.refundReservedBalance(pr, "no_terminal_after_cancel:"+pr.RequestID)
		return
	}
	s.settlements.hold(pr, s.terminalSettleGrace(), func(expired *registry.PendingRequest) {
		// Only log a refund if this call actually finalized it. With
		// park-before-remove, a request settled by handleComplete can leave a
		// duplicate here; FinalizeReservation makes the refund a no-op in that
		// case (returns false) — don't claim a refund that didn't happen.
		if s.refundReservedBalance(expired, "no_terminal_after_cancel:"+expired.RequestID) {
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
