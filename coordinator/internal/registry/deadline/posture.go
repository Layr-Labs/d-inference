package deadline

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// PosturePolicy consumes actual session activity and posture invalidations.
// Operations remain serialized by the provider owner's existing critical section.
type PosturePolicy interface {
	Activity(time.Time)
	InvalidatePosture(time.Time)
	Allows(*Profile, bool, time.Time) bool
	Reset()
}

type Posture struct{ activityAt, invalidAt time.Time }

func (p *Posture) Activity(now time.Time) {
	if now.After(p.activityAt) {
		p.activityAt = now
	}
}

func (p *Posture) InvalidatePosture(now time.Time) {
	if now.After(p.invalidAt) {
		p.invalidAt = now
	}
}

func (p *Posture) Allows(profile *Profile, quiet bool, now time.Time) bool {
	if profile == nil || !ValidApplicability(profile.MinimumWholeMacQuiescenceMS, profile.MinimumNominalStabilityMS, profile.PowerMode) {
		return false
	}
	return quiet && elapsedWindow(now, p.invalidAt, *profile.MinimumNominalStabilityMS) &&
		elapsedWindow(now, p.activityAt, *profile.MinimumWholeMacQuiescenceMS)
}

func (p *Posture) Reset() {
	p.activityAt, p.invalidAt = time.Time{}, time.Time{}
}

func elapsedWindow(now, invalidatedAt time.Time, millis int) bool {
	// Conditional provider proof supplies the initial window. Once invalidated,
	// a backwards clock cannot restore it.
	return invalidatedAt.IsZero() || (!now.Before(invalidatedAt) && now.Sub(invalidatedAt) >= time.Duration(millis)*time.Millisecond)
}

// ReportedQuiescent covers every slot, including models outside the catalog.
func ReportedQuiescent(capacity *protocol.BackendCapacity) bool {
	if capacity == nil || capacity.WholeMacServiceUsed == nil || *capacity.WholeMacServiceUsed != 0 ||
		len(capacity.WholeMacServiceReservations) != 0 || (capacity.LoadTransitionActive != nil && *capacity.LoadTransitionActive) {
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
		if (slot.State != "running" && slot.State != "idle") || !ValidWork(slot.DeadlineWork, slot.PerformanceMeasurements) ||
			slot.DeadlineWork.RequestCount != 0 {
			return false
		}
	}
	return true
}
