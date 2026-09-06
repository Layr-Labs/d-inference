package registry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// CatalogEntry holds metadata about an active model in the catalog.
type CatalogEntry struct {
	ID                           string
	WeightHash                   string  // expected SHA-256 weight fingerprint (empty = not enforced)
	SizeGB                       float64 // disk/GPU footprint of the model weights (zero = unknown, gate disabled)
	RequiredProviderCapabilities []string
	// MinRAMGB is the catalog's authoritative minimum unified memory (GB) to run
	// this model — the operator-published requirement. The hardware-fit gate
	// prefers this over any heuristic multiple of SizeGB. Zero = unknown.
	MinRAMGB int
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
		e.RequiredProviderCapabilities = effectiveRequiredProviderCapabilities(
			e.ID, e.RequiredProviderCapabilities)
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

// IsAliasLineageBuild reports whether buildID is a PREVIOUS or RETIRED member of
// any active alias — i.e. an old build that a hot-swap migration legitimately
// leaves GPU-resident on providers after it drops from the advertised set. Used
// to scope the attestation active-hash alibi to exactly that migration case, so
// a provider can't use the alibi to claim an arbitrary unrelated catalog model
// as active. (Desired members are still advertised, so they never need it.)
func (r *Registry) IsAliasLineageBuild(buildID string) bool {
	if buildID == "" {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, t := range r.modelAliases {
		if t.Previous == buildID {
			return true
		}
		for _, retired := range t.Retired {
			if retired == buildID {
				return true
			}
		}
	}
	return false
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
		if m.ID == model && r.providerModelAllowedByCatalogLocked(p, m) {
			return true
		}
	}
	return false
}

// modelTrackedByCatalogLocked reports whether the catalog has an entry for the
// model id at all (regardless of weight-hash agreement). A nil catalog tracks
// nothing — filtering is disabled and modelAllowedByCatalogLocked admits
// everything, so callers never reach the off-catalog distinction. Caller must
// hold r.mu.
func (r *Registry) modelTrackedByCatalogLocked(id string) bool {
	if r.modelCatalog == nil {
		return false
	}
	_, ok := r.modelCatalog[id]
	return ok
}

// modelServableForOwnerLocked is the owner self-route admission for a single
// advertised build: a model the catalog does NOT track is servable on the
// owner's box, while catalog builds retain their integrity and provider
// capability requirements. The exact protected Qwen build keeps its
// requirements even with catalog filtering disabled. Caller holds r.mu and
// p.mu.
func (r *Registry) modelServableForOwnerLocked(p *Provider, m protocol.ModelInfo) bool {
	return (r.modelAllowedByCatalogLocked(m) || !r.modelTrackedByCatalogLocked(m.ID)) &&
		r.providerMeetsModelRequirementsLocked(p, m.ID)
}

// providerServesOwnedRoutableModelLocked is providerServesCatalogModelLocked's
// owner self-route counterpart: true when the provider advertises the model
// and that build is servable for its owner (catalog-allowed, or absent from
// the catalog entirely). Caller must hold r.mu and p.mu.
func (r *Registry) providerServesOwnedRoutableModelLocked(p *Provider, model string) bool {
	for _, m := range p.Models {
		if m.ID == model && r.modelServableForOwnerLocked(p, m) {
			return true
		}
	}
	return false
}

// providerServesVisionModelLocked reports whether the provider advertises the
// model as a vision-capable (VLM) build — required to route image/video requests
// so the media is actually perceived rather than silently dropped. allowOffCatalog
// is the owner self-route context (mirrors providerServesRoutableModelLocked's
// allowDedicated): an owner's off-catalog local VLM passes the routable gate, so
// the vision gate must accept the same advertisement or media requests would be
// listed/accepted but never routable. It relaxes only catalog MEMBERSHIP — a
// catalog-tracked build still has to pass the weight-hash gate, mirroring the
// routable gate. Caller must hold r.mu AND p.mu (mirrors
// providerServesCatalogModelLocked): p.Models is guarded by p.mu and mutated by
// MergeProviderModels/UpdateModelWeightHashes. Pre-0.6.0 providers never set
// IsVision, so they are correctly excluded.
func (r *Registry) providerServesVisionModelLocked(p *Provider, model string, allowOffCatalog bool) bool {
	for _, m := range p.Models {
		if m.ID != model || !m.IsVision {
			continue
		}
		if allowOffCatalog {
			if !r.modelServableForOwnerLocked(p, m) {
				continue
			}
		} else if !r.providerModelAllowedByCatalogLocked(p, m) {
			continue
		}
		if model == modelpolicy.Qwen3VL30BA3BInstructModelID &&
			strings.EqualFold(strings.TrimSpace(p.Hardware.ChipFamily), "M5") {
			// This concrete VLM produces incorrect visual inference on M5.
			return false
		}
		return true
	}
	return false
}

// HasVisionProviderForModel reports whether any online, non-untrusted provider
// advertises a vision-capable build for the resolved model id. The consumer uses
// it to fail a media request fast with a clear error when the fleet has no
// VLM-capable provider for the model (e.g. before the gemma fleet finishes
// updating to 0.6.0), instead of queueing the request to a timeout.
//
// When allowedSerials is non-empty the check is restricted to providers whose
// attested serial is in the set, exactly as the routing path constrains the
// candidate pool. Without this filter a constrained media request would be
// falsely reported as serviceable by an unrelated public provider (the same
// latent gap as HasToolCapableProviderForModel).
func (r *Registry) HasVisionProviderForModel(model string, allowedSerials ...string) bool {
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		// Allowed-serial filter first (providerMatchesAllowedSerial takes p.mu
		// internally), mirroring the routing candidate filter and QuickCapacityCheck.
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		// p.Status and p.Models are guarded by p.mu (writers hold it), so the
		// whole eligibility read must happen under the provider lock.
		p.mu.Lock()
		eligible := p.Status != StatusOffline && p.Status != StatusUntrusted &&
			r.providerServesVisionModelLocked(p, model, false)
		p.mu.Unlock()
		if eligible {
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

// advertisedModelSizeGBLocked returns the provider-advertised on-disk weight
// size for model in decimal GB (SizeBytes/1e9 — the same unpadded basis as the
// catalog's SizeGB), or 0 when the provider does not advertise the model or
// reports no size. Caller must hold p.mu.
func advertisedModelSizeGBLocked(p *Provider, model string) float64 {
	for _, m := range p.Models {
		if m.ID == model && m.SizeBytes > 0 {
			return float64(m.SizeBytes) / 1e9
		}
	}
	return 0
}

// modelSizeGBForFitLocked returns the weight footprint (GB) the hardware-fit
// and free-memory admission gates should use for a provider/model pair: the
// catalog's authoritative SizeGB when present, else — for a model with NO
// catalog entry (an owner's off-catalog local model, reachable only via
// self-route) — the provider-advertised size. Without the fallback an
// off-catalog model snapshots as size 0, disabling both gates, so routing
// could pick a machine whose oversized local model can never load and turn a
// deterministic model_too_large into a provider-side load failure. A nil
// catalog (dev/test: filtering disabled) and a catalog entry the operator left
// unsized both keep the gate disabled, as before. Caller holds r.mu and p.mu.
func (r *Registry) modelSizeGBForFitLocked(p *Provider, model string) float64 {
	if size := r.catalogSizeGBLocked(model); size > 0 {
		return size
	}
	if r.modelCatalog == nil {
		return 0
	}
	if _, ok := r.modelCatalog[model]; ok {
		return 0
	}
	return advertisedModelSizeGBLocked(p, model)
}

// catalogMinRAMGbLocked returns the model's authoritative minimum-RAM
// requirement (GB) from the catalog, or 0 when unknown. Caller must hold r.mu.
func (r *Registry) catalogMinRAMGbLocked(model string) int {
	if e, ok := r.modelCatalog[model]; ok {
		return e.MinRAMGB
	}
	return 0
}
