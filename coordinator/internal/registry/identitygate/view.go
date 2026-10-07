package identitygate

import "time"

// View captures one identity's routing evidence. Confirm rebases a view whose
// live session moved; callers repeat their decision before committing it.
type View struct {
	directory *Directory
	g         *State
	p         *Session
	rereads   int
}

func (r *Directory) ViewForSession(session *Session, id string) View {
	if session != nil {
		if g := session.gate.Load(); g != nil {
			return (View{directory: r, g: g, p: session}).Resolve()
		}
	}
	return View{directory: r, g: r.lookupGateForSession(id), p: session}
}

func (r *Directory) ViewIdentity(key string) View {
	return View{directory: r, g: r.lookupGateForKey(key)}
}

func (r *Directory) ViewReference(ref Reference) View {
	return View{directory: r, g: ref.g, p: ref.p}
}

func (v View) Present() bool { return v.g != nil }

func (v View) SameIdentity(other View) bool { return v.g == other.g }

// Resolve follows a completed identity migration without changing the captured
// session provenance. Shared source identities have no forwarding edge.
func (v View) Resolve() View {
	for {
		next, advanced := v.FollowMigration()
		if !advanced {
			return v
		}
		v = next
	}
}

// FollowMigration advances one published identity migration, leaving a shared
// source unchanged when another live session still owns it.
func (v View) FollowMigration() (View, bool) {
	if v.g == nil {
		return v, false
	}
	next := v.g.forwardTo.Load()
	if next == nil {
		return v, false
	}
	v.g = next
	return v, true
}

func (v View) MatchesIdentity(key string) bool { return v.g != nil && v.g.key == key }

// InferenceHistory reads the collection's owned chronological evidence, including
// coordinator disconnect provenance, without exposing its model/shape indexes.
func (v View) InferenceHistory(model, shape string) (strikes, flush []time.Time) {
	if v.g == nil {
		return nil, nil
	}
	g := v.g.lockResolved()
	defer g.mu.Unlock()
	return g.inference.Chronological(model, shape)
}

func (v View) RateHistory(model string) (rejects, accepts []time.Time) {
	if v.g == nil {
		return nil, nil
	}
	g := v.g.lockResolved()
	defer g.mu.Unlock()
	return g.capacityRateHistory.Chronological(model)
}

// Confirm reports that the caller must repeat its reads on the updated view.
func (v *View) Confirm() bool {
	if v.p == nil || v.rereads >= gateRelockMaxRetries {
		return false
	}
	cur := v.p.gate.Load()
	if cur == nil {
		return false
	}
	if cur = cur.resolve(); cur == v.g {
		return false
	}
	v.g = cur
	v.rereads++
	return true
}

func (v View) BreakerOpenAt(nowNS int64) bool { return v.g.breakerOpenAt(nowNS) }
func (v View) EjectedAt(nowNS int64) bool     { return v.g.ejectedAt(nowNS) }
func (v View) DispatchLoadCooled(model string, now time.Time) bool {
	return v.g.dispatchLoadCooled(model, now)
}
func (v View) InferenceErrorCooled(model, shape string, now time.Time) bool {
	return v.g.inferenceErrorCooled(model, shape, now)
}
func (v View) CapacityCooled(model string, now time.Time) bool { return v.g.capacityCooled(model, now) }

func (v View) EjectionOpenFor(identity string, nowNS int64) bool {
	if identity == "" || v.directory == nil {
		return false
	}
	if v.MatchesIdentity(identity) {
		return v.EjectedAt(nowNS)
	}
	return v.directory.ViewIdentity(identity).EjectedAt(nowNS)
}

func (v View) CapacityRatePenalty(model string, now time.Time) (float64, float64) {
	if v.directory == nil {
		return 0, 0
	}
	return v.g.capacityRatePenalty(v.directory.capacityRateCfg, model, now)
}

func (v View) BudgetClampActive(model string, heartbeatAt time.Time, remaining int64, reported bool, now time.Time) bool {
	if v.directory == nil {
		return false
	}
	return v.g.budgetClampActive(v.directory.budgetClampCfg, model, heartbeatAt, remaining, reported, now)
}
