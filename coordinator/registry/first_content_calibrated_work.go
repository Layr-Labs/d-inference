package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
)

// fillCalibratedWorkSnapshot joins full existing-work upper bounds with exact
// service-lease correlation. Receipt time never proves a pending request was
// included. Missing pre-submit, local, or retirement ownership stays unknown.
// Caller holds p.mu; profile resolution needs no additional registry lock.
func fillCalibratedWorkSnapshot(s *routingSnapshot, p *Provider, now time.Time, report capacityvalue.ServiceReport) {
	builder, known := deadline.BoundSlotsWithReport(p.deadlineProfiles, deadline.Identity{Version: p.Version, Hardware: p.Hardware,
		Models: p.Models, Capacity: p.BackendCapacity, Metrics: p.SystemMetrics}, s.model, report)
	if !known {
		return
	}
	if !p.serviceRetirement.Cover(&builder, p.BackendCapacity.WholeMacServiceReservations) {
		return
	}
	for _, pending := range p.pendingReqs {
		if !builder.Pending(deadline.PendingWork{Model: pending.Model, PromptWork: pending.PromptWork,
			RequestedMaxTokens: pending.RequestedMaxTokens, ServiceCharge: pending.reservedServiceCharge},
			p.reportedServiceChargeLocked(pending.ServiceReservationID())) {
			return
		}
	}
	s.calibratedWork, s.calibratedWorkKnown = builder.Finish(), true
	if m, ok := p.firstContentMeasurements.Lookup(s.model); ok {
		s.calibratedDecodeTPS = m.DecodeRate
		if !m.ContendedObservedAfter.IsZero() && !m.DecodeObservedAfter.IsZero() {
			s.contendedPerformanceAgeMs = max(heartbeatAgeMs(now, m.ContendedObservedAfter), heartbeatAgeMs(now, m.DecodeObservedAfter))
			s.contendedPrefillTPS = m.ContendedRate
		}
	}
}

func finiteServiceFraction(v float64) bool { return deadline.FiniteServiceFraction(v) }
