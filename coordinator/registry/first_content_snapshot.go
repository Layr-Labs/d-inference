package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
)

// fillFirstContentSnapshot is part of the ordinary snapshot lock, never an
// additional provider read. Whole-Mac service work uses bounded expected output
// demand, not maximum-token memory commitments. Reported/local work overlap is
// reconciled per model with max, so one request is not charged twice.
func (r *Registry) fillFirstContentSnapshot(s *routingSnapshot, p *Provider, now time.Time) {
	s.capacityAcceptedAt, s.capacitySeq = p.CapacityAcceptedAt, p.capacitySeq
	s.transportMs, s.conservativeTransportMs, s.transportAgeMs = p.transport.Forecast(now)
	s.capacityAgeMs, s.performanceAgeMs = -1, -1
	s.contendedPerformanceAgeMs = -1
	s.promptWorkArtifactHash, s.promptWorkContractID = providerPromptWorkIdentityLocked(p, s.model)
	if !p.CapacityAcceptedAt.IsZero() {
		s.capacityAgeMs = heartbeatAgeMs(now, p.CapacityAcceptedAt)
	}
	if sample, ok := p.firstContentMeasurements.Lookup(s.model); ok && !sample.ObservedAfter.IsZero() && !sample.DecodeObservedAfter.IsZero() {
		s.performanceAgeMs = max(heartbeatAgeMs(now, sample.ObservedAfter), heartbeatAgeMs(now, sample.DecodeObservedAfter))
	}
	s.evidenceGapAgeMs = firstContentEvidenceGapAgeMs(s, p.connectionOrigin, now)
	capacity := p.BackendCapacity
	if capacity == nil {
		return
	}
	// Idle slot counters do not prove retirement: service leases can outlive
	// consumer terminals, and model loading can start before a slot appears.
	// Legacy providers may omit service fields; their slot evidence still applies.
	s.wholeMacBusy = p.serviceRetirement.Account(nil).Retiring > 0 ||
		(capacity.WholeMacServiceUsed != nil && *capacity.WholeMacServiceUsed != 0) ||
		len(capacity.WholeMacServiceReservations) > 0 ||
		(capacity.LoadTransitionActive != nil && *capacity.LoadTransitionActive)
	fillCalibratedWorkSnapshot(s, p, now)
	builder := forecast.NewWorkBuilder(s.model, capacity, p.CapacityAcceptedAt, s.decodeTPS, s.prefillTPS, s.wholeMacBusy)
	for i := range capacity.Slots {
		slot := &capacity.Slots[i]
		t := slot.Telemetry
		known := t != nil && t.QueuedPrefillTokens != nil && t.PartialPrefillRows != nil
		if slot.Model == s.model {
			s.prefillWorkloadRates = snapshotPrefillWorkloadRates(slot.PerformanceMeasurements, p.CapacityAcceptedAt)
			s.modelLoadMs = float64(slot.ModelLoadTimeMS)
			if s.modelLoaded {
				s.modelLoadMs = 0
			}
			if known {
				s.queuedPrefillKnown = true
				s.queuedPrefillTokens = max(0, *t.QueuedPrefillTokens)
				s.partialPrefillRows = int(max(0, *t.PartialPrefillRows))
			}
			if t != nil {
				if t.IsolatedPrefillTPS != nil {
					s.isolatedPrefillTPS = *t.IsolatedPrefillTPS
				}
				s.isolatedPrefillInitialized = t.EWMAInitialized != nil && *t.EWMAInitialized
				if measurements := slot.PerformanceMeasurements; measurements != nil {
					s.isolatedPrefillInitialized = capacityvalue.ValidPerformanceObservation(measurements.IsolatedPrefill)
					if s.isolatedPrefillInitialized {
						s.isolatedPrefillTPS = measurements.IsolatedPrefill.TokensPerSecond
					}
				}
			}
		}
		builder.BeginSlot(i)
		for _, pending := range p.pendingReqs {
			builder.Pending(firstContentPendingWork(pending))
		}
		builder.EndSlot()
	}
	for _, pending := range p.pendingReqs {
		builder.UnreportedPending(firstContentPendingWork(pending))
	}
	work := builder.Finish()
	s.wholeMacWorkKnown, s.wholeMacBusy = work.WholeMacKnown, work.WholeMacBusy
	s.otherModelOccupancy += work.OtherModelOccupancy
	s.wholeMacServiceMs += work.ServiceMS
}

func firstContentPendingWork(pr *PendingRequest) forecast.PendingWork {
	return forecast.PendingWork{Model: pr.Model, ReservedAt: pr.reservedAt, RequestedMaxTokens: pr.RequestedMaxTokens,
		EstimatedPromptTokens: pr.EstimatedPromptTokens, ContentCommitted: pr.ContentCommittedSafe(),
		ReservedPrefillKnown: pr.reservedPrefillKnown, ReservedPrefillTokens: pr.reservedPrefillTokens, ReservedPrefillRestoreMS: pr.reservedPrefillRestoreMs}
}
