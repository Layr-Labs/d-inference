package registry

import "math"

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
	if p.BackendCapacity == nil || p.BackendCapacity.WholeMacServiceUsed == nil {
		return true // old providers retain existing count/memory admission
	}
	reported := *p.BackendCapacity.WholeMacServiceUsed
	if math.IsNaN(reported) || math.IsInf(reported, 0) || reported < 0 || reported > 1+1e-12 {
		return false
	}
	if !validWholeMacServiceReservations(p.BackendCapacity) {
		return false
	}
	used := reported
	for _, pending := range p.pendingReqs {
		charge := pending.reservedServiceCharge
		if charge <= 0 { // legacy/test owner without a captured profile charge
			charge = p.serviceChargeForModelLocked(pending.Model)
		}
		reportedCharge := 0.0
		if id := pending.ServiceReservationID(); id != "" {
			for _, reservation := range p.BackendCapacity.WholeMacServiceReservations {
				if reservation.ID == id {
					reportedCharge = reservation.UsedFraction
					break
				}
			}
		}
		used += max(0, charge-reportedCharge)
	}
	return used+p.serviceChargeForModelLocked(model) <= 1+1e-12
}
