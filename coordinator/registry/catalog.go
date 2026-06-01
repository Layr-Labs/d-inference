package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TruncHash returns the first 16 chars of a hash string for logging.
func TruncHash(h string) string {
	if len(h) > 16 {
		return h[:16] + "..."
	}
	return h
}

// CatalogEntry holds metadata about an active model in the catalog.
type CatalogEntry struct {
	ID         string
	WeightHash string  // expected SHA-256 weight fingerprint (empty = not enforced)
	SizeGB     float64 // disk/GPU footprint of the model weights (zero = unknown, gate disabled)
}

// SetModelCatalog updates the set of active models. Only models in this
// set will be accepted from providers during registration and routable to
// consumers. Pass nil to disable catalog filtering for tests/dev flows. Passing
// an empty non-nil slice configures a deny-all catalog, which is what a fresh
// DB-backed registry should do until an operator registers and promotes models.
func (r *Registry) SetModelCatalog(entries []CatalogEntry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if entries == nil {
		r.modelCatalog = nil
		return
	}
	catalog := make(map[string]CatalogEntry, len(entries))
	for _, e := range entries {
		catalog[e.ID] = e
	}
	r.modelCatalog = catalog
}

// ModelType returns the model type string for the given model ID, or
// "unknown" if no provider is currently serving it.
func (r *Registry) ModelType(model string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		for _, m := range p.Models {
			if m.ID == model && m.ModelType != "" {
				p.mu.Unlock()
				return m.ModelType
			}
		}
		p.mu.Unlock()
	}
	return "unknown"
}

// IsModelInCatalog returns true if the model is in the active catalog, or if
// catalog filtering has been explicitly disabled by setting a nil catalog.
func (r *Registry) IsModelInCatalog(model string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.modelCatalog == nil {
		return true
	}
	_, ok := r.modelCatalog[model]
	return ok
}

// CatalogWeightHash returns the expected weight hash for a model, or empty
// string if not set or not in catalog.
func (r *Registry) CatalogWeightHash(model string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if e, ok := r.modelCatalog[model]; ok {
		return e.WeightHash
	}
	return ""
}

// modelAllowedByCatalogLocked returns whether a provider-reported model is
// allowed by the current catalog. Caller must hold r.mu (read or write). A nil
// catalog disables filtering; an empty non-nil catalog denies all models.
func (r *Registry) modelAllowedByCatalogLocked(model protocol.ModelInfo) bool {
	if r.modelCatalog == nil {
		return true
	}
	entry, ok := r.modelCatalog[model.ID]
	if !ok {
		return false
	}
	return entry.WeightHash == "" || model.WeightHash == "" || model.WeightHash == entry.WeightHash
}

// providerServesCatalogModelLocked returns true if the provider advertises the
// model and that model is currently allowed by the catalog. Caller must hold
// r.mu and p.mu.
func (r *Registry) providerServesCatalogModelLocked(p *Provider, model string) bool {
	for _, m := range p.Models {
		if m.ID == model && r.modelAllowedByCatalogLocked(m) {
			return true
		}
	}
	return false
}

// catalogSizeGBLocked returns the model's reported weight footprint in GB,
// or 0 when unknown. Caller must hold r.mu (read or write). Zero means the
// memory-admission gate should not enforce for this model — typically a
// catalog entry that pre-dates the SizeGB field, or a model the operator
// hasn't sized yet.
func (r *Registry) catalogSizeGBLocked(model string) float64 {
	if e, ok := r.modelCatalog[model]; ok {
		return e.SizeGB
	}
	return 0
}

// trustMeetsMinimum returns true if the given trust level meets the minimum.
func (r *Registry) trustMeetsMinimum(level TrustLevel) bool {
	return trustRank(level) >= trustRank(r.MinTrustLevel)
}
