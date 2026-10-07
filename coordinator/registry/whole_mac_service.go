package registry

import (
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

// HasHeadroom reconciles captured reservations with the producer's service
// report. Only exact lease IDs establish overlap; receipt time cannot prove it. The caller holds the provider lock through admission commitment.
func (s *ServiceReservations) HasHeadroom(model string) bool {
	return s.hasHeadroomWithReport(model, capacityvalue.NewServiceReport(s.provider.BackendCapacity))
}

// hasHeadroomWithReport uses validation borrowed for this provider critical
// section. Standalone admission callers validate through HasHeadroom.
func (s *ServiceReservations) hasHeadroomWithReport(model string, report capacityvalue.ServiceReport) bool {
	p := s.provider
	if p.BackendCapacity == nil || p.BackendCapacity.WholeMacServiceUsed == nil {
		return !p.serviceRetirementProtocol // opted-in sessions cannot reset accounting by omitting capacity
	}
	if !report.ValidFor(p.BackendCapacity) {
		return false
	}
	reported := *p.BackendCapacity.WholeMacServiceUsed
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
