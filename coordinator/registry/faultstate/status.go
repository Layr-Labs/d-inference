package faultstate

import "time"

// Status is a copied diagnostic for one identity and one model/shape. Histories
// never alias the owner. State changes only through its transaction methods.
type Status struct {
	EjectionPresent                                          bool
	BreakerTotal, BreakerFails, EjectionTotal, EjectionFails int
	CapacityCooldownKeys                                     int
	Found                                                    bool
	Key                                                      string
	Retired                                                  bool
	BreakerPresent                                           bool
	BreakerUntil                                             time.Time
	BreakerTrips                                             int
	BreakerConsecutive                                       int
	BreakerOutcomes                                          int
	EjectionConsecutive                                      int
	InferenceStrikeKeys                                      int
	InferenceCooldownKeys                                    int
	EjectionUntil                                            time.Time
	EjectionTrips                                            int
	EjectionCapacityCount                                    int
	VersionResetAt                                           time.Time
	InferenceStrikes                                         []time.Time
	DispatchLoadUntil                                        time.Time
	CapacityStrikes                                          []time.Time
	CapacityUntil                                            time.Time
	CapacityProbeAt                                          time.Time
	CapacityTrips                                            int
	CapacityPresent                                          bool
	ClampPresent                                             bool
	ClampAt                                                  time.Time
	ClampAccepted                                            bool
	ClampBudgetReported                                      bool
	RateRejects                                              []time.Time
	RateAccepts                                              []time.Time
}

func (g *gateState) status(model, shape string) Status {
	if g == nil {
		return Status{}
	}
	g = g.lockResolved()
	defer g.mu.Unlock()
	s := Status{Found: true, Key: g.key, Retired: g.retired, BreakerPresent: g.outcomes != nil, BreakerUntil: g.breakerUntil, BreakerTrips: g.breakerTrips, EjectionUntil: g.ejectionUntil, EjectionTrips: g.ejectionTrips, EjectionCapacityCount: g.ejectionCapacityStreak.n, VersionResetAt: g.versionResetAt,
		InferenceStrikes: append([]time.Time(nil), g.inferenceErrorStrikes[modelShapeKey{Model: model, Shape: shape}]...), DispatchLoadUntil: g.dispatchLoadCooldowns[model],
		CapacityStrikes: append([]time.Time(nil), g.capacityRejectStrikes[model]...), CapacityTrips: g.capacityCooldownTrips[model],
		RateRejects: append([]time.Time(nil), g.capacityRateRejects[model]...), RateAccepts: append([]time.Time(nil), g.capacityRateAccepts[model]...)}
	s.CapacityCooldownKeys = len(g.capacityCooldowns)
	s.EjectionPresent = g.ejection != nil
	if g.outcomes != nil {
		s.BreakerTotal, s.BreakerFails = g.outcomes.windowStats(time.Now(), providerBreakerWindow)
	}
	if g.ejection != nil {
		s.EjectionTotal, s.EjectionFails = g.ejection.windowStats(time.Now(), healthEjectionWindow)
	}
	s.InferenceStrikeKeys = len(g.inferenceErrorStrikes)
	s.InferenceCooldownKeys = len(g.inferenceErrorCooldowns)
	if g.ejection != nil {
		s.EjectionConsecutive = g.ejection.consecFail
	}
	if g.outcomes != nil {
		s.BreakerConsecutive = g.outcomes.consecFail
		s.BreakerOutcomes = g.outcomes.size
	}
	if e := g.capacityCooldowns[model]; e != nil {
		s.CapacityPresent = true
		s.CapacityUntil = e.expiry
		s.CapacityProbeAt = e.probeAt
	}
	if e := g.budgetClamps[model]; e != nil {
		s.ClampPresent = true
		s.ClampAt = e.clampedAt
		s.ClampAccepted = e.acceptedSince
		s.ClampBudgetReported = e.budgetReported
	}
	return s
}
func (r *Manager[C]) StatusForSession(id, model, shape string) Status {
	return r.lookupGateForSession(id).status(model, shape)
}
func (r *Manager[C]) StatusForKey(key, model, shape string) Status {
	return r.lookupGateForKey(key).status(model, shape)
}
func (r *Manager[C]) ViewForKey(key string) View[C] {
	return View[C]{owner: r, g: r.lookupGateForKey(key)}
}
func (r *Manager[C]) FiledView(key string) View[C] {
	r.gatesMu.RLock()
	g := r.gates[key]
	r.gatesMu.RUnlock()
	return View[C]{owner: r, g: g}
}
func (v View[C]) Present() bool { return v.g != nil }
func (v View[C]) Key() string {
	if v.g == nil {
		return ""
	}
	return v.g.key
}
func (v View[C]) SameGate(other View[C]) bool { return v.g == other.g }
func (v View[C]) Rereads() int                { return v.rereads }
func (v View[C]) Forwarded() bool             { return v.g != nil && v.g.forwardTo.Load() != nil }

// IdentityStatus is a copied index row. The index lock retains filing while
// each leaf is read, using the same index-to-gate order as migration and sweep.
type IdentityStatus struct {
	Key     string
	Live    int
	Retired bool
}

func (r *Manager[C]) IndexStatus() []IdentityStatus {
	r.gatesMu.RLock()
	defer r.gatesMu.RUnlock()
	rows := make([]IdentityStatus, 0, len(r.gates))
	for key, g := range r.gates {
		g.mu.Lock()
		rows = append(rows, IdentityStatus{Key: key, Live: g.live, Retired: g.retired})
		g.mu.Unlock()
	}
	return rows
}
