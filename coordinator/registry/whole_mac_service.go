package registry

import "math"

func (p *Provider) serviceChargeForModelLocked(model string) float64 {
	if profile := qualifiedPerformanceProfileLocked(p, model); profile != nil {
		return 1 / float64(profile.WholeMacConcurrency)
	}
	return 1.0 / 24 // preserve existing unknown-profile whole-provider allowance
}

// Reconcile report/local overlap and then add reservations created after the
// report. This is checked again under the provider lock at atomic commitment.
func (p *Provider) hasWholeMacServiceHeadroomLocked(model string) bool {
	if p.BackendCapacity == nil || p.BackendCapacity.WholeMacServiceUsed == nil {
		return true // old providers retain existing count/memory admission
	}
	reported := *p.BackendCapacity.WholeMacServiceUsed
	if math.IsNaN(reported) || math.IsInf(reported, 0) || reported < 0 || reported > 1+1e-12 {
		return false
	}
	overlap, fresh := 0.0, 0.0
	for _, pending := range p.pendingReqs {
		charge := pending.reservedServiceCharge
		if charge <= 0 { // legacy/test owner without a captured profile charge
			charge = p.serviceChargeForModelLocked(pending.Model)
		}
		if !p.CapacityAcceptedAt.IsZero() && !pending.reservedAt.Before(p.CapacityAcceptedAt) {
			fresh += charge
		} else {
			overlap += charge
		}
	}
	return max(reported, overlap)+fresh+p.serviceChargeForModelLocked(model) <= 1+1e-12
}
