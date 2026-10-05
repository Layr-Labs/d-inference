package registry

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (e *ProviderEligibility) CanAcquireDesired(id, desired, previous string) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.desiredLocked(p, desired, previous)
}

func (e *ProviderEligibility) AutopilotGates(id string, model protocol.ModelInfo, traits RequestTraits, now time.Time) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.autopilotGatesLocked(p, model, traits, now)
}

func (e *ProviderEligibility) desiredLocked(p *Provider, desired, previous string) bool {
	return e.canAcquireLocked(p, desired) ||
		(providerSelectedModelLocked(p, previous) && e.canAcquireArtifactLocked(p, desired))
}

func (e *ProviderEligibility) autopilotGatesLocked(p *Provider, model protocol.ModelInfo, traits RequestTraits, now time.Time) bool {
	r := e.registry
	// Test the complete permission set a live lease exposes, not only the
	// ordinary shadow set, which could hide mixed-inventory dedication failures.
	if pattern, dedicated := r.dedicatedPatternForLocked(model.ID); dedicated {
		for _, candidate := range p.Models {
			if r.modelAllowedByCatalogLocked(candidate) && r.providerMeetsModelRequirementsLocked(p, candidate.ID) &&
				(providerSelectedModelLocked(p, candidate.ID) || providerAutopilotAllowsLocked(p, candidate.ID)) &&
				!strings.Contains(strings.ToLower(candidate.ID), pattern) {
				return false
			}
		}
	}
	if !p.autopilotState.ObserverOnly(model.ID) {
		ok, _ := e.routingLocked(p, model.ID, traits, false, now, false, false)
		return ok
	}
	if model.WeightHash == "" || !providerAutopilotAllowsLocked(p, model.ID) || !r.modelAllowedByCatalogLocked(model) ||
		!r.providerMeetsModelRequirementsLocked(p, model.ID) || r.providerExcludedByDedicatedRuleLocked(p, model.ID) {
		return false
	}
	ok, _ := e.postCatalogLocked(p, model.ID, traits, false, now, false, false)
	return ok
}
