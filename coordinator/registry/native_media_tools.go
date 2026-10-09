package registry

func providerSupportsNativeMediaToolsLocked(p *Provider, model string) bool {
	if !providerSupportsToolConstraintLocked(p, model) {
		return false
	}
	for _, info := range p.Models {
		if info.ID == model {
			return info.IsVision && info.NativeMediaTools
		}
	}
	return false
}

func (r *Registry) HasNativeMediaToolProviderForRouting(model, owner string, selfOnly, prefer bool, serials ...string) bool {
	traits := RequestTraits{HasTools: true, RequiresToolConstraint: true, RequiresNativeMediaTools: true}
	return r.hasToolCapableProviderForModel(model, traits, owner, selfOnly, prefer, nil, serials...)
}

// Match the ordinary advertisement scan; freshness/capacity outages must stay
// retryable rather than being mistaken for a permanently unsupported feature.
func (r *Registry) HasProviderAdvertisingNativeMediaTools(model string, serials ...string) bool {
	allowed := make(map[string]struct{}, len(serials))
	for _, serial := range serials {
		allowed[serial] = struct{}{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		if len(allowed) > 0 && !providerMatchesAllowedSerial(p, allowed) {
			continue
		}
		p.mu.Lock()
		ok := p.Status != StatusOffline && p.Status != StatusUntrusted && r.providerServesCatalogModelLocked(p, model) && providerSupportsNativeMediaToolsLocked(p, model)
		p.mu.Unlock()
		if ok {
			return true
		}
	}
	return false
}
