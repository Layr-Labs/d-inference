package registry

import "time"

import "github.com/eigeninference/d-inference/coordinator/registry/faultstate"

// rawGateForKey checks filing first, then returns a copied diagnostic. Mutable
// owner fields and locks never cross this integration-test boundary.
func rawGateForKey(r *Registry, key string) *faultstate.Status {
	if !r.faults.FiledView(key).Present() {
		return nil
	}
	s := r.faults.StatusForKey(key, "", "")
	return &s
}
func sessionIndexed(r *Registry, id string) bool { return r.sessionProvider(id) != nil }
func gateHasBreakerWindow(r *Registry, key string) bool {
	return r.faults.StatusForKey(key, "", "").BreakerPresent
}

// The probe fixture retains the exact Provider separately from the opaque
// pending claim. Its captured view permits read-only publication assertions.
type gateProbeFixture struct {
	p     *Provider
	g     faultstate.View[*Provider]
	claim faultstate.CapacityProbe[*Provider]
}

func (r *Registry) probeGateRef(p *Provider) gateProbeFixture {
	claim := r.faults.PrepareCapacityProbe(&p.faultSession, p.ID)
	return gateProbeFixture{p: p, g: claim.View(), claim: claim}
}
func (r *Registry) claimCapacityProbeRef(ref gateProbeFixture, model string, now time.Time) bool {
	return ref.claim.Claim(model, now)
}
