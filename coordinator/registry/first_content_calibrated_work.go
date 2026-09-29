package registry

import (
	"math"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

// fillCalibratedWorkSnapshot joins full existing-work upper bounds with exact
// service-lease correlation. Receipt time never proves a pending request was
// included. Missing pre-submit, local, or retirement ownership stays unknown.
// Caller holds p.mu; profile resolution needs no additional registry lock.
func fillCalibratedWorkSnapshot(s *routingSnapshot, p *Provider, now time.Time) {
	capacity := p.BackendCapacity
	if capacity == nil || capacity.WholeMacServiceUsed == nil || !validWholeMacServiceReservations(capacity) {
		return
	}
	// Weight loading and load-gate updates can consume device work before a
	// model has a serving slot or a correlated request lease.
	if capacity.LoadTransitionActive != nil && *capacity.LoadTransitionActive {
		return
	}
	reported := *capacity.WholeMacServiceUsed
	if !finiteServiceFraction(reported) {
		return
	}
	work := firstcontent.Work{}
	service := 0.0
	competitors := make(map[string]bool)
	targetFound := false
	evaluating := false
	for _, slot := range capacity.Slots {
		w := slot.DeadlineWork
		busy := slot.NumRunning > 0 || slot.NumWaiting > 0 || slot.EvalInFlightMs > 0 || slot.IdleClearInFlightMs > 0 || slot.WedgeSuspected ||
			(w != nil && (w.RequestCount > 0 || w.ServiceFraction > 0))
		if t := slot.Telemetry; t != nil {
			busy = busy || (t.QueuedPrefillTokens != nil && *t.QueuedPrefillTokens > 0) || (t.PartialPrefillRows != nil && *t.PartialPrefillRows > 0)
		}
		if slot.Model != s.model && !busy {
			continue
		}
		if !validDeadlineWork(w, slot.PerformanceMeasurements) || !slotStateModelLoaded(slot.State) || slot.WedgeSuspected || slot.IdleClearInFlightMs > 0 {
			return
		}
		if w.RequestCount < slot.NumRunning+slot.NumWaiting {
			return
		}
		if t := slot.Telemetry; t != nil {
			if (t.QueuedPrefillTokens != nil && *t.QueuedPrefillTokens > w.PrefillTokens) ||
				(t.PartialPrefillRows != nil && *t.PartialPrefillRows > int64(w.RequestCount)) {
				return
			}
		}
		evaluating = evaluating || slot.EvalInFlightMs > 0
		profile := qualifiedDeadlineProfileLocked(p, slot.Model)
		if profile == nil || w.ContextTokensMax > profile.measuredContextTokensMax() {
			return
		}
		work.PrefillTokens += float64(w.PrefillTokens)
		work.DecodeTokens += float64(w.DecodeTokens)
		work.ActiveRequests += w.RequestCount
		service += w.ServiceFraction
		if slot.Model == s.model {
			targetFound = true
			work.ContextTokens = max(work.ContextTokens, w.ContextTokensMax)
		} else {
			work.OtherModelRequests += w.RequestCount
			work.OtherModelServiceFraction += w.ServiceFraction
			competitors[profile.ID] = true
		}
	}
	if !targetFound || math.Abs(service-reported) > 1e-9 || (evaluating && work.ActiveRequests == 0) {
		return
	}
	// An explicit release has not yet proved these terminal owners retired.
	// They are bounded only while the producer still reports their exact lease.
	for id, charge := range p.serviceRetirementShadows {
		if p.reportedServiceChargeLocked(id)+1e-12 < charge {
			return
		}
	}
	for _, pending := range p.pendingReqs {
		if charge := p.reportedServiceChargeLocked(pending.ServiceReservationID()); charge > 0 {
			if charge+1e-12 < pending.reservedServiceCharge {
				// A changed fraction cannot prove the entire frozen owner was
				// represented by this producer workload snapshot.
				return
			}
			continue
		}
		profile := qualifiedDeadlineProfileLocked(p, pending.Model)
		if profile == nil || profile.DeadlineCalibration == nil ||
			!pending.PromptWork.IsQualifiedFor(profile.ArtifactSHA256, profile.DeadlineCalibration.PromptContractID) ||
			pending.RequestedMaxTokens <= 0 || pending.RequestedMaxTokens > profile.measuredContextTokensMax() ||
			pending.PromptWork.UpperBoundTokens > profile.measuredContextTokensMax()-pending.RequestedMaxTokens ||
			!finiteServiceFraction(pending.reservedServiceCharge) || pending.reservedServiceCharge == 0 {
			return
		}
		work.PrefillTokens += float64(pending.PromptWork.UpperBoundTokens)
		work.DecodeTokens += float64(pending.RequestedMaxTokens)
		work.ActiveRequests++
		if pending.Model == s.model {
			work.ContextTokens = max(work.ContextTokens, pending.PromptWork.UpperBoundTokens+pending.RequestedMaxTokens)
		} else {
			work.OtherModelRequests++
			work.OtherModelServiceFraction += pending.reservedServiceCharge
			competitors[profile.ID] = true
		}
	}
	for id := range competitors {
		work.CompetitorProfileIDs = append(work.CompetitorProfileIDs, id)
	}
	sort.Strings(work.CompetitorProfileIDs)
	s.calibratedWork, s.calibratedWorkKnown = work, true
	if m, ok := p.firstContentMeasurements[s.model]; ok {
		s.calibratedDecodeTPS = m.decodeRate
		if !m.contendedObservedAfter.IsZero() && !m.decodeObservedAfter.IsZero() {
			s.contendedPerformanceAgeMs = max(heartbeatAgeMs(now, m.contendedObservedAfter), heartbeatAgeMs(now, m.decodeObservedAfter))
			s.contendedPrefillTPS = m.contendedRate
		}
	}
}

func finiteServiceFraction(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= 0 && v <= 1+1e-12
}

func validDeadlineWork(w *protocol.DeadlineWork, measurements *protocol.PerformanceMeasurements) bool {
	if w == nil || w.Version != 1 || !w.Known || measurements == nil || w.Epoch == "" || w.Epoch != measurements.Epoch ||
		len(w.Epoch) > 64 || w.PrefillTokens < 0 || w.DecodeTokens < 0 || w.PrefillTokens > 1<<30 || w.DecodeTokens > 1<<30 ||
		w.RequestCount < 0 || w.RequestCount > 64 || w.ContextTokensMax < 0 || w.ContextTokensMax > 1<<20 || !finiteServiceFraction(w.ServiceFraction) {
		return false
	}
	if w.RequestCount == 0 {
		return w.PrefillTokens == 0 && w.DecodeTokens == 0 && w.ContextTokensMax == 0 && w.ServiceFraction == 0
	}
	// The producer retains each lease's full original positive prompt through
	// cache reuse and retirement. Zero output is valid; zero prompt work for a
	// nonempty owner set cannot be a known envelope from that producer.
	if w.PrefillTokens < int64(w.RequestCount) || w.ContextTokensMax <= 0 || w.ServiceFraction <= 0 {
		return false
	}
	// Context is the maximum of each owner's full prompt+output; every other
	// owner still contributes at least one token. The validated field caps above
	// keep both this sum and count*context within int64 bounds.
	total := w.PrefillTokens + w.DecodeTokens
	context := int64(w.ContextTokensMax)
	count := int64(w.RequestCount)
	return context <= total-(count-1) && total <= count*context
}
