package registry

import (
	"strings"
	"time"

	"github.com/google/uuid"
)

// The terminal shadow owns only a frozen UUID/fraction, never the mutable
// PendingRequest reused by a retry. It is still part of admission's service
// sum, so it cannot grow without bound by retiring requests faster than leases.
// No timeout, heartbeat omission, sequence or receive timestamp proves release.
func (p *Provider) retainServiceRetirementShadowLocked(pr *PendingRequest) {
	if pr == nil || !pr.serviceRetirementTracked || !pr.serviceHandoffAuthorized || pr.serviceReservationReleased {
		return
	}
	id := pr.ServiceReservationID()
	if id == "" {
		return
	}
	if p.serviceRetirementShadows == nil {
		p.serviceRetirementShadows = make(map[string]float64)
	}
	p.serviceRetirementShadows[id] = pr.reservedServiceCharge
}

// The writer alone can prove an authorized frame was never handed to the
// socket. Terminal cleanup may already have moved it to a shadow by this point.
func (p *Provider) abortServiceReservationHandoff(id string) {
	p.mu.Lock()
	_, released := p.serviceRetirementShadows[id]
	delete(p.serviceRetirementShadows, id)
	if released {
		p.recordDeadlineActivityLocked(time.Now())
	}
	for _, pr := range p.pendingReqs {
		if pr.ServiceReservationID() == id {
			pr.serviceHandoffAuthorized = false
			// The writer may return cancellation while its final authorization
			// callback is still waiting for this lock. Fence that later callback.
			pr.serviceHandoffAborted = true
			p.recordDeadlineActivityLocked(time.Now())
			break
		}
	}
	p.mu.Unlock()
	if released && p.registry != nil {
		p.registry.SetProviderIdle(p.ID)
	}
}

// ReleaseServiceReservation accepts producer retirement proof for this live
// connection. Unknown/duplicate IDs allocate nothing, including late callbacks
// from an old provider connection. Temporary untrust retains lease ownership;
// disconnect clears it. Caller need not be publicly routable to retire work.
func (r *Registry) ReleaseServiceReservation(p *Provider, id string) bool {
	if p == nil || len(id) != 36 || uuid.Validate(id) != nil {
		return false
	}
	id = strings.ToLower(id)
	r.mu.RLock()
	if r.providers[p.ID] != p {
		r.mu.RUnlock()
		return false
	}
	p.mu.Lock()
	released := p.releaseServiceReservationLocked(id)
	p.mu.Unlock()
	r.mu.RUnlock()
	if released {
		r.SetProviderIdle(p.ID)
	}
	return released
}

func (p *Provider) releaseServiceReservationLocked(id string) bool {
	if !p.serviceRetirementProtocol {
		return false
	}
	if _, ok := p.serviceRetirementShadows[id]; ok {
		delete(p.serviceRetirementShadows, id)
		p.recordDeadlineActivityLocked(time.Now())
		return true
	}
	for _, pr := range p.pendingReqs {
		if pr.serviceRetirementTracked && !pr.serviceReservationReleased && pr.ServiceReservationID() == id {
			pr.serviceReservationReleased = true
			p.recordDeadlineActivityLocked(time.Now())
			return true
		}
	}
	return false
}
