package identitygate

import "time"

// CooldownDecision describes quarantine and its single pending recovery probe.
type CooldownDecision struct {
	RetryAfter time.Time
	ProbeAt    time.Time
	Trips      int
}

func (d CooldownDecision) Active(now time.Time) bool {
	return now.Before(d.RetryAfter) || (!d.ProbeAt.IsZero() && now.Before(d.ProbeAt.Add(capacityProbeOutcomeWindow)))
}

func (d CooldownDecision) claim(now time.Time) (CooldownDecision, bool) {
	if now.Before(d.RetryAfter) {
		return d, false
	}
	if d.ProbeAt.IsZero() || !now.Before(d.ProbeAt.Add(capacityProbeOutcomeWindow)) {
		d.ProbeAt = now
		return d, true
	}
	return d, false
}

// CapacityAssessment is the evidence consumed by probe admission and rebuilding
// the cooldown after an observed accept. Public reads own their strike slice.
type CapacityAssessment struct {
	Present  bool
	Decision CooldownDecision
	Strikes  []time.Time
}

// RebuildCapacityCooldown applies surviving rejects as a fresh streak. Earlier
// backoff does not carry across an accept; a still-applicable claimed probe does.
func RebuildCapacityCooldown(cfg CapacityCooldownConfig, strikes []time.Time, previous CooldownDecision) CooldownDecision {
	if cfg.Threshold <= 0 || len(strikes) < cfg.Threshold {
		return CooldownDecision{}
	}
	var expiry time.Time
	trips := 0
	for i, strike := range strikes {
		if strike.Before(expiry) || (trips == 0 && i+1 < cfg.Threshold) {
			continue
		}
		expiry = strike.Add(capacityCooldownBackoff(cfg, trips))
		trips++
	}
	result := CooldownDecision{RetryAfter: expiry, Trips: trips}
	if !previous.ProbeAt.IsZero() && !previous.ProbeAt.Before(expiry) {
		result.ProbeAt = previous.ProbeAt
	}
	return result
}

func (g *State) capacityAssessmentLocked(model string) CapacityAssessment {
	e, ok := g.capacityCooldowns[model]
	a := CapacityAssessment{Present: ok, Strikes: g.capacityRejectStrikes[model]}
	a.Decision.Trips = g.capacityCooldownTrips[model]
	if ok {
		a.Decision.RetryAfter = e.expiry
		a.Decision.ProbeAt = e.probeAt
	}
	return a
}

func (v View) CapacityAssessment(model string) CapacityAssessment {
	if v.g == nil {
		return CapacityAssessment{}
	}
	g := v.g.lockResolved()
	defer g.mu.Unlock()
	a := g.capacityAssessmentLocked(model)
	a.Strikes = append([]time.Time(nil), a.Strikes...)
	return a
}
