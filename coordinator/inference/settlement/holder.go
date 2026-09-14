package settlement

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// DefaultGrace bounds how long a disconnected request's billing
// record waits for the provider's terminal before its reservation is refunded.
// A connected provider aborts within ms; 30s is a wide WS-latency margin. The
// record lives outside the provider's pending set, so it doesn't count against
// concurrency/idle while waiting.
const DefaultGrace = 30 * time.Second

// Holder parks the billing record of a consumer-disconnected request
// so a late provider terminal can settle it (charge delivered tokens) instead of
// hitting "unknown request" — which would leak the reservation and pay $0. No
// terminal within the grace → refund. Claim is single-winner (terminal handler
// vs. grace timer); FinalizeReservation independently guards double-counting.
type Holder struct {
	mu      sync.Mutex
	pending map[string]*registry.PendingRequest
}

func NewHolder() *Holder {
	return &Holder{pending: make(map[string]*registry.PendingRequest)}
}

// Hold stores pr under its request id and schedules onExpiry(pr) after grace if
// it has not been claimed by then. onExpiry runs at most once for a held record.
func (h *Holder) Hold(pr *registry.PendingRequest, grace time.Duration, onExpiry func(*registry.PendingRequest)) {
	if pr == nil {
		return
	}
	h.mu.Lock()
	h.pending[pr.RequestID] = pr
	h.mu.Unlock()

	time.AfterFunc(grace, func() {
		if expired := h.Claim(pr.RequestID); expired != nil {
			onExpiry(expired)
		}
	})
}

// Claim removes and returns the held record for requestID, or nil if none
// (already claimed, expired, or never held).
func (h *Holder) Claim(requestID string) *registry.PendingRequest {
	h.mu.Lock()
	defer h.mu.Unlock()
	pr, ok := h.pending[requestID]
	if !ok {
		return nil
	}
	delete(h.pending, requestID)
	return pr
}
