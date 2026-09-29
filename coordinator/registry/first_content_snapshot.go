package registry

import "time"

// fillFirstContentSnapshot is part of the ordinary snapshot lock, never an
// additional provider read. Whole-Mac service work uses bounded expected output
// demand, not maximum-token memory commitments. Reported/local work overlap is
// reconciled per model with max, so one request is not charged twice.
func (r *Registry) fillFirstContentSnapshot(s *routingSnapshot, p *Provider, now time.Time) {
	s.capacityAcceptedAt, s.capacitySeq = p.CapacityAcceptedAt, p.capacitySeq
	s.transportMs, s.conservativeTransportMs, s.transportAgeMs = transportForecast(p.transport, now)
	s.capacityAgeMs, s.performanceAgeMs = -1, -1
	if !p.CapacityAcceptedAt.IsZero() {
		s.capacityAgeMs = heartbeatAgeMs(now, p.CapacityAcceptedAt)
	}
	if sample, ok := p.firstContentMeasurements[s.model]; ok && !sample.observedAfter.IsZero() && !sample.decodeObservedAfter.IsZero() {
		s.performanceAgeMs = max(heartbeatAgeMs(now, sample.observedAfter), heartbeatAgeMs(now, sample.decodeObservedAfter))
	}
	capacity := p.BackendCapacity
	if capacity == nil {
		return
	}
	s.wholeMacWorkKnown = len(capacity.Slots) > 0
	for i := range capacity.Slots {
		slot := &capacity.Slots[i]
		t := slot.Telemetry
		known := t != nil && t.QueuedPrefillTokens != nil && t.PartialPrefillRows != nil
		busy := slot.NumRunning > 0 || slot.NumWaiting > 0 || slot.EvalInFlightMs > 0 ||
			slot.IdleClearInFlightMs > 0 || slot.WedgeSuspected
		if t != nil {
			busy = busy || (t.QueuedPrefillTokens != nil && *t.QueuedPrefillTokens > 0) ||
				(t.PartialPrefillRows != nil && *t.PartialPrefillRows > 0)
		}
		// An unrelated idle_shutdown slot has evicted its weights and does not
		// compete for execution. Its missing telemetry is not missing evidence
		// about active work. Positive activity signals override that state, and
		// local reservations are still accounted below even for dormant slots.
		dormant := slot.Model != s.model && slot.State == "idle_shutdown" && !busy
		if !dormant {
			s.wholeMacWorkKnown = s.wholeMacWorkKnown && known
			s.wholeMacBusy = s.wholeMacBusy || busy || !slotStateModelLoaded(slot.State)
		}
		if slot.Model == s.model {
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
					s.isolatedPrefillInitialized = validPerformanceObservation(measurements.IsolatedPrefill)
					if s.isolatedPrefillInitialized {
						s.isolatedPrefillTPS = measurements.IsolatedPrefill.TokensPerSecond
					}
				}
			}
		}
		// The ordinary snapshot already resolved registration/hardware defaults.
		// Read this canonical slot directly instead of walking/copying all slots
		// again for every co-resident model.
		decode, prefill := s.decodeTPS, s.prefillTPS
		if slot.ObservedDecodeTPS > 0 {
			decode = slot.ObservedDecodeTPS
		}
		if slot.ObservedPrefillTPS > 0 {
			prefill = slot.ObservedPrefillTPS
		}
		decode, prefill = max(1, decode), max(1, prefill)
		reported := float64(max(0, slot.NumRunning)+max(0, slot.NumWaiting)) * defaultRequestedMaxTokens / decode * 1000
		if t != nil && t.QueuedPrefillTokens != nil {
			reported += float64(max(0, *t.QueuedPrefillTokens)) / prefill * 1000
		}
		local, unreported := 0.0, 0.0
		localCount, unreportedCount := 0, 0
		for _, pending := range p.pendingReqs {
			if pending.Model == slot.Model {
				work := firstContentPendingServiceMs(pending, decode, prefill)
				if !p.CapacityAcceptedAt.IsZero() && !pending.reservedAt.Before(p.CapacityAcceptedAt) {
					// Work reserved after this capacity frame cannot already be in
					// its counters. Reconcile overlap, then add known new work.
					unreported += work
					unreportedCount++
				} else {
					local += work
					localCount++
				}
			}
		}
		if slot.Model != s.model {
			s.otherModelOccupancy += max(localCount, int(max(0, slot.NumRunning)+max(0, slot.NumWaiting))) + unreportedCount
		}
		s.wholeMacServiceMs += max(reported, local) + unreported
	}
	// Reservations for a cold/unreported model still consume this Mac's work.
	for _, pending := range p.pendingReqs {
		present := false
		for i := range capacity.Slots {
			if capacity.Slots[i].Model == pending.Model {
				present = true
				break
			}
		}
		if !present {
			s.wholeMacServiceMs += firstContentPendingServiceMs(pending, max(1, s.decodeTPS), max(1, s.prefillTPS))
			if pending.Model != s.model {
				s.otherModelOccupancy++
			}
		}
		// Exact GPU progress of local reservations is not known, even when the
		// latest idle heartbeat has not reflected them yet.
		s.wholeMacBusy = true
	}
}

func firstContentPendingServiceMs(pr *PendingRequest, decode, prefill float64) float64 {
	output := defaultRequestedMaxTokens
	if pr.RequestedMaxTokens > 0 {
		output = min(output, pr.RequestedMaxTokens)
	}
	work := float64(output) / decode * 1000
	if !pr.ContentCommittedSafe() {
		prompt := float64(max(0, pr.EstimatedPromptTokens))
		if pr.reservedPrefillKnown {
			prompt = pr.reservedPrefillTokens
		}
		work += prompt/prefill*1000 + pr.reservedPrefillRestoreMs
	}
	return work
}
