package registry

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/serviceretirement"
)

// ServiceReservationID snapshots the current committed attempt's opaque lease
// identity. Writer frames freeze this value before a later attempt can replace it.
func (pr *PendingRequest) ServiceReservationID() string {
	if id := pr.serviceReservationID.Load(); id != nil {
		return id.wire
	}
	return ""
}

func (p *Provider) serviceChargeForModelLocked(model string) float64 {
	if profile := qualifiedPerformanceProfileLocked(p, model); profile != nil {
		return 1 / float64(profile.WholeMacConcurrency)
	}
	return 1.0 / 24 // preserve existing unknown-profile whole-provider allowance
}

// Only exact reservation IDs prove report/local overlap. Receipt time cannot
// prove a delayed report contains a reservation, especially with local traffic.
// This is checked again under the provider lock at atomic commitment.
func (p *Provider) hasWholeMacServiceHeadroomLocked(model string) bool {
	return p.serviceReservationsLocked().HasHeadroom(model)
}

// HasHeadroom reconciles captured reservations with the producer's service
// report. The caller holds the provider lock through admission commitment.
func (s *ServiceReservations) HasHeadroom(model string) bool {
	p := s.provider
	if p.BackendCapacity == nil || p.BackendCapacity.WholeMacServiceUsed == nil {
		return !p.serviceRetirementProtocol // opted-in sessions cannot reset accounting by omitting capacity
	}
	reported := *p.BackendCapacity.WholeMacServiceUsed
	if math.IsNaN(reported) || math.IsInf(reported, 0) || reported < 0 || reported > 1+1e-12 {
		return false
	}
	if !capacityvalue.ValidWholeMacServiceReservations(p.BackendCapacity) {
		return false
	}
	used := reported
	used += p.serviceRetirement.Account(p.BackendCapacity.WholeMacServiceReservations).UnreportedCharge
	for _, pending := range p.pendingReqs {
		charge := pending.reservedServiceCharge
		if charge <= 0 { // legacy/test owner without a captured profile charge
			charge = p.serviceChargeForModelLocked(pending.Model)
		}
		reportedCharge := p.reportedServiceChargeLocked(pending.ServiceReservationID())
		used += max(0, charge-reportedCharge)
	}
	return used+p.serviceChargeForModelLocked(model) <= 1+1e-12
}

func (p *Provider) reportedServiceChargeLocked(id string) float64 {
	return serviceretirement.ReportedCharge(p.BackendCapacity.WholeMacServiceReservations, id)
}
