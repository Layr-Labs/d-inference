package identitygate

import "time"

// HealthAssessment is the bounded evidence and recovery state used to decide
// whether a terminal outcome starts another quarantine interval.
type HealthAssessment struct {
	HasHistory        bool
	Samples           int
	Failures          int
	ConsecutiveFaults int
	Trips             int
	RetryAfter        time.Time
	CapacityOrigin    bool
}

func (a HealthAssessment) NeedsProbe() bool { return a.Trips > 0 }

func (a HealthAssessment) breakerRateTrips() bool {
	return a.HasHistory && a.Samples >= providerBreakerMinVolume && float64(a.Failures) > providerBreakerFailRate*float64(a.Samples)
}

func (a HealthAssessment) ejectionRateTrips() bool {
	return a.HasHistory && a.Samples >= healthEjectionMinSample && float64(a.Samples-a.Failures) < healthEjectionMinSuccessRate*float64(a.Samples)
}

func (g *State) breakerAssessmentLocked(now time.Time) HealthAssessment {
	a := HealthAssessment{Trips: g.breakerTrips, RetryAfter: g.breakerUntil}
	if w := g.outcomes; w != nil {
		a.HasHistory = true
		a.Samples, a.Failures = w.WindowStats(now, providerBreakerWindow)
		a.ConsecutiveFaults = w.FaultStreak()
	}
	return a
}

func (g *State) ejectionAssessmentLocked(now time.Time) HealthAssessment {
	a := HealthAssessment{Trips: g.ejectionTrips, RetryAfter: g.ejectionUntil, CapacityOrigin: g.ejectionLastTripCapacity}
	if w := g.ejection; w != nil {
		a.HasHistory = true
		a.Samples, a.Failures = w.WindowStats(now, healthEjectionWindow)
		a.ConsecutiveFaults = w.FaultStreak()
	}
	return a
}

func (v View) BreakerHealth(now time.Time) HealthAssessment {
	if v.g == nil {
		return HealthAssessment{}
	}
	g := v.g.lockResolved()
	defer g.mu.Unlock()
	return g.breakerAssessmentLocked(now)
}

func (v View) EjectionHealth(now time.Time) HealthAssessment {
	if v.g == nil {
		return HealthAssessment{}
	}
	g := v.g.lockResolved()
	defer g.mu.Unlock()
	return g.ejectionAssessmentLocked(now)
}
