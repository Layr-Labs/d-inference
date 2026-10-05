package identitygate

import "time"

// BudgetClampAssessment is the dated evidence for a pair's admission hold and
// release. It is a value, independent of the gate's mutable clamp entry.
type BudgetClampAssessment struct {
	Present        bool
	ClampedAt      time.Time
	AcceptedSince  bool
	BudgetReported bool
}

func (a BudgetClampAssessment) Active(ttl time.Duration, heartbeatAt time.Time, remaining int64, budgetReported bool, now time.Time) bool {
	// Budgetless rejects never gate, even after a later budgeted heartbeat;
	// a clamp cannot demand proof of service from a pair it never admitted.
	if !a.Present || !now.Before(a.ClampedAt.Add(ttl)) || !a.BudgetReported {
		return false
	}
	if !budgetReported {
		// A reconnect's missing telemetry cannot shed a budgeted clamp.
		return true
	}
	return !(a.AcceptedSince && heartbeatAt.After(a.ClampedAt) && remaining >= budgetClampReleaseMinHeadroomTokens)
}

func (g *State) budgetClampAssessmentLocked(model string) BudgetClampAssessment {
	e, ok := g.budgetClamps[model]
	if !ok {
		return BudgetClampAssessment{}
	}
	return BudgetClampAssessment{Present: true, ClampedAt: e.clampedAt, AcceptedSince: e.acceptedSince, BudgetReported: e.budgetReported}
}

func (v View) BudgetClampAssessment(model string) BudgetClampAssessment {
	if v.g == nil {
		return BudgetClampAssessment{}
	}
	g := v.g.lockResolved()
	defer g.mu.Unlock()
	return g.budgetClampAssessmentLocked(model)
}
