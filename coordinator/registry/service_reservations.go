package registry

import "time"

// ServiceReservations owns admission's pending-service mutation on one provider.
// The provider and pending request fields remain private and every operation
// shares the provider lock with heartbeat, handoff and terminal processing.
type ServiceReservations struct {
	provider *Provider
}

func (r *Registry) bindServiceReservations(p *Provider) {
	p.serviceReservations = &p.defaultServiceReservations
	if r.serviceReservationsFactory != nil {
		if owner := r.serviceReservationsFactory(p.ID); owner != nil {
			p.serviceReservations = owner
		}
	}
	p.serviceReservations.provider = p
}

func (p *Provider) serviceReservationsLocked() *ServiceReservations {
	if p.serviceReservations == nil {
		p.defaultServiceReservations.provider = p
		p.serviceReservations = &p.defaultServiceReservations
	}
	return p.serviceReservations
}

// Add captures the resolved service charge with the pending request. The caller
// holds the provider lock, including while resolving the model's service charge.
func (s *ServiceReservations) Add(pr *PendingRequest, charge float64) {
	p := s.provider
	pr.providerAuthorizationBinding = providerRequestAuthorizationBindingLocked(p)
	pr.reservedAt = time.Now()
	p.recordDeadlineActivityLocked(pr.reservedAt)
	pr.reservedServiceCharge = charge
	pr.serviceRetirementTracked = p.serviceRetirementProtocol
	pr.serviceHandoffAuthorized = false
	pr.serviceHandoffAborted = false
	pr.serviceReservationReleased = false
	pr.serviceReservationID.Store(newServiceReservationIdentity())
	p.pendingReqs[pr.RequestID] = pr
	p.drain.ReservationAdded()
}

// ReleasePending applies producer retirement proof before request termination.
// The caller holds the provider lock and has established connection authority.
// A legacy or already released attempt cannot consume this proof.
func (s *ServiceReservations) ReleasePending(id string) bool {
	p := s.provider
	for _, pr := range p.pendingReqs {
		if pr.serviceRetirementTracked && !pr.serviceReservationReleased && pr.ServiceReservationID() == id {
			pr.serviceReservationReleased = true
			p.recordDeadlineActivityLocked(time.Now())
			return true
		}
	}
	return false
}
