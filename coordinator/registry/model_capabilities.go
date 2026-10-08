package registry

// HasProviderForModel reports whether any online, non-untrusted provider
// advertises a catalog-allowed build of the resolved model id (ignoring
// transient routing and capacity gates). When allowedSerials is non-empty the
// check is restricted to providers whose attested serial is in the set,
// mirroring the routing candidate filter.
func (r *Registry) HasProviderForModel(model string, allowedSerials ...string) bool {
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		p.mu.Lock()
		eligible := p.Status != StatusOffline && p.Status != StatusUntrusted &&
			r.providerServesCatalogModelLocked(p, model)
		p.mu.Unlock()
		if eligible {
			return true
		}
	}
	return false
}

// HasProviderAdvertisingToolConstraint reports whether any online,
// non-untrusted provider advertising a catalog-allowed build of the resolved
// model id ALSO advertises inference-time tool_choice enforcement for it
// (tool-constraint protocol v1 with the concrete model listed). It mirrors
// HasProviderForModel's gate set exactly — status, catalog membership, serial
// allowlist — and deliberately IGNORES trust minimums, attestation freshness,
// and capacity: it answers "can this fleet EVER enforce tool_choice for this
// model", not "can it right now". The consumer uses it to split the permanent
// 400 ("no build of this model enforces tool_choice") from the transient 503;
// a trust-lapsed or freshness-expired enforcing provider is a transient
// outage that belongs to the retryable 503 arm.
func (r *Registry) HasProviderAdvertisingToolConstraint(model string, allowedSerials ...string) bool {
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		p.mu.Lock()
		eligible := p.Status != StatusOffline && p.Status != StatusUntrusted &&
			r.providerServesCatalogModelLocked(p, model) &&
			providerSupportsToolConstraintLocked(p, model)
		p.mu.Unlock()
		if eligible {
			return true
		}
	}
	return false
}
