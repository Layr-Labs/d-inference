package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func validDeadlineApplicability(quiescence, stability *int, powerMode string) bool {
	// The sole promoter certifies this exact recovery policy. Other windows
	// require a new measured policy, not edits to compiled release data.
	return quiescence != nil && *quiescence == 20000 &&
		stability != nil && *stability == 5000 && powerMode == "automatic"
}

// An advertised exact profile is the producer's proof of its reviewed power
// policy and stable observation window. Missing live posture is not nominal.
func deadlineNominalPosture(capacity *protocol.BackendCapacity, metrics protocol.SystemMetrics) bool {
	return metrics.ThermalState == "nominal" && capacity != nil && capacity.Telemetry != nil &&
		capacity.Telemetry.LowPowerMode != nil && !*capacity.Telemetry.LowPowerMode
}

// Unknown activity cannot establish quiescence. This checks every slot, even
// models outside the coordinator's catalog, because the evidence is Mac-wide.
func deadlineReportedQuiescent(capacity *protocol.BackendCapacity) bool {
	if capacity == nil || capacity.WholeMacServiceUsed == nil || *capacity.WholeMacServiceUsed != 0 ||
		len(capacity.WholeMacServiceReservations) != 0 ||
		(capacity.LoadTransitionActive != nil && *capacity.LoadTransitionActive) {
		return false
	}
	for _, slot := range capacity.Slots {
		if slot.NumRunning != 0 || slot.NumWaiting != 0 || slot.ActiveTokens != 0 ||
			slot.ActiveTokenBudgetUsed != 0 || slot.QueuedTokenBudget != 0 || slot.EvalInFlightMs != 0 ||
			slot.IdleClearInFlightMs != 0 || slot.WedgeSuspected {
			return false
		}
		if t := slot.Telemetry; t != nil {
			if (t.QueuedPrefillTokens != nil && *t.QueuedPrefillTokens != 0) ||
				(t.PartialPrefillRows != nil && *t.PartialPrefillRows != 0) ||
				(t.EvalInFlightMS != nil && *t.EvalInFlightMS != 0) {
				return false
			}
		}
		if slot.State == "idle_shutdown" && slot.DeadlineWork == nil {
			continue
		}
		if !slotStateModelLoaded(slot.State) || !validDeadlineWork(slot.DeadlineWork, slot.PerformanceMeasurements) ||
			slot.DeadlineWork.RequestCount != 0 {
			return false
		}
	}
	return true
}

func (p *Provider) recordDeadlineActivityLocked(now time.Time) {
	if now.After(p.deadlineActivityAt) {
		p.deadlineActivityAt = now
	}
}

// Called only for an accepted heartbeat. Sequence rejection must not change
// either clock. These clocks record invalidation, never evidence of retirement.
func (p *Provider) reconcileDeadlineApplicabilityLocked(capacity *protocol.BackendCapacity, metrics protocol.SystemMetrics, now time.Time) {
	if !deadlineReportedQuiescent(capacity) {
		p.recordDeadlineActivityLocked(now)
	}
	if !deadlineNominalPosture(capacity, metrics) && now.After(p.deadlinePostureInvalidAt) {
		p.deadlinePostureInvalidAt = now
	}
}

// Caller holds r.mu and p.mu. Provider proof cannot override intervening local
// work, including a terminal whose real engine retirement is still outstanding.
func (r *Registry) deadlineProfileApplicableLocked(p *Provider, profile *deadlinePerformanceProfile, now time.Time) bool {
	if profile == nil || !validDeadlineApplicability(profile.MinimumWholeMacQuiescenceMS, profile.MinimumNominalStabilityMS, profile.PowerMode) ||
		!elapsedDeadlineWindow(now, p.deadlinePostureInvalidAt, *profile.MinimumNominalStabilityMS) {
		return false
	}
	quiescence := *profile.MinimumWholeMacQuiescenceMS
	if len(p.pendingReqs) != 0 || len(p.serviceRetirementShadows) != 0 || r.providerHasPendingLoad(p.ID) || providerAutopilotTransitionLocked(p) ||
		!deadlineReportedQuiescent(p.BackendCapacity) {
		return false
	}
	return elapsedDeadlineWindow(now, p.deadlineActivityAt, quiescence)
}

func elapsedDeadlineWindow(now, invalidatedAt time.Time, millis int) bool {
	// With no locally observed invalidation, the conditional provider reference
	// supplies the proof. Once invalidated, a backwards clock cannot restore it.
	return invalidatedAt.IsZero() || (!now.Before(invalidatedAt) && now.Sub(invalidatedAt) >= time.Duration(millis)*time.Millisecond)
}

// Registry-only load mutations use the normal r.mu -> p.mu lock order.
func (r *Registry) recordDeadlineLoadActivityLocked(providerID string, now time.Time) {
	if p := r.providers[providerID]; p != nil {
		p.mu.Lock()
		p.recordDeadlineActivityLocked(now)
		p.mu.Unlock()
	}
}
