package registry

// IsSystemOneModel identifies catalog-owned native decision models, including
// public aliases. Provider declarations are only used in catalog-free tests
// and development; they cannot change a production model's endpoint.
func (r *Registry) IsSystemOneModel(model string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if target, ok := r.modelAliases[model]; ok {
		model = target.Desired
	}
	if entry, ok := r.modelCatalog[model]; ok {
		return entry.SystemOne
	}
	if r.modelCatalog != nil {
		return false
	}
	for _, p := range r.providers {
		p.mu.Lock()
		for _, m := range p.Models {
			if m.ID == model && (m.ModelType == "laya" || m.SystemOne) {
				p.mu.Unlock()
				return true
			}
		}
		p.mu.Unlock()
	}
	return false
}

// Caller holds r.mu and p.mu. Capability is carried in Models, so register,
// authoritative models_update replacement, and disconnect share its lifecycle.
func (r *Registry) providerSystemOneEligibleLocked(p *Provider, model string, native bool) bool {
	entry, catalogued := r.modelCatalog[model]
	for _, m := range p.Models {
		if m.ID != model {
			continue
		}
		decisionModel := m.ModelType == "laya" || m.SystemOne
		if catalogued {
			decisionModel = entry.SystemOne
		}
		if native {
			return decisionModel && m.SystemOne && m.ModelType == "laya"
		}
		return !decisionModel && !m.SystemOne && m.ModelType != "laya"
	}
	return !native && !entry.SystemOne
}

// HasSystemOneProviderForRouting checks the native capability with the same
// trust, ownership, serial, and catalog constraints as actual dispatch.
func (r *Registry) HasSystemOneProviderForRouting(model, owner string, selfOnly, preferOwner bool, serials ...string) bool {
	return r.hasToolCapableProviderForModel(model, RequestTraits{SystemOne: true}, owner, selfOnly, preferOwner, nil, serials...)
}

// SystemOneQuestion retains only the request's answer schema in memory. It must
// never enter persisted profiles, routing records, or logs.
type SystemOneQuestion struct {
	Type    string
	Options map[string]struct{}
	Levels  int
	Legend  []any
}
