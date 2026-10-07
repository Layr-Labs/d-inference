// Package settlement holds detached requests until a terminal or grace expiry claims them.
package settlement

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Holder parks the billing record of a consumer-disconnected request
// so a late provider terminal can settle it instead of hitting "unknown request".
// Claim is single-winner (terminal handler vs. grace timer);
// FinalizeReservation independently guards double-counting in the owner.
type Holder struct {
	mu      sync.Mutex
	pending map[string]*registry.PendingRequest
}

func New() *Holder {
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
