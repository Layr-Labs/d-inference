package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
)

// ProviderEligibility holds the registry read lease for eligibility decisions.
// Each operation evaluates current provider evidence under the provider lock;
// neither the provider nor its captured state escapes the operation.
type ProviderEligibility struct {
	registry *Registry
	closed   bool
}

func (p *ReservationPlanner) PrepareEligibility() *ProviderEligibility {
	p.registry.mu.RLock()
	return &ProviderEligibility{registry: p.registry}
}

// Close releases the read lease. It must not race with an eligibility operation.
func (e *ProviderEligibility) Close() {
	if e != nil && !e.closed {
		e.closed = true
		e.registry.mu.RUnlock()
	}
}

func (e *ProviderEligibility) provider(id string) *Provider {
	if e == nil || e.closed {
		return nil
	}
	return e.registry.providers[id]
}

func (e *ProviderEligibility) Routing(id, model string, traits RequestTraits, selfRouteOwner bool, now time.Time, ignoreProviderBreaker, ignoreCapacityCooldown bool) (bool, GateReason) {
	p := e.provider(id)
	if p == nil {
		return false, GateOffline
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.routingLocked(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, ignoreCapacityCooldown)
}

// Build checks build eligibility without request-specific capacity admission.
// Structural probes omit transient cooldowns and slot states.
func (e *ProviderEligibility) Build(id, model string, minTrust TrustLevel, now time.Time, allowPrivate, structural bool) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if structural {
		return e.structuralBuildLocked(p, model, minTrust, now, allowPrivate)
	}
	return e.buildLocked(p, model, minTrust, now, allowPrivate)
}

func (e *ProviderEligibility) Public(id string, now time.Time) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.publicLocked(p, now)
}

func (e *ProviderEligibility) ServesCatalog(id, model string) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.servesCatalogLocked(p, model)
}

func (e *ProviderEligibility) ServesOwned(id, model string) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.servesOwnedLocked(p, model)
}

func (e *ProviderEligibility) CanAcquire(id, model string) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.canAcquireLocked(p, model)
}

func (e *ProviderEligibility) CanAcquireArtifact(id, model string) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.canAcquireArtifactLocked(p, model)
}

func (e *ProviderEligibility) DeadlineApplicable(id string, profile *deadline.Profile, now time.Time) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.deadlineApplicableLocked(p, profile, now)
}
