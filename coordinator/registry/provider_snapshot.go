package registry

// ProviderSnapshot is a flat, read-only view of the per-provider fields the
// base-rewards engine needs to build settlement candidates. It is a copy taken
// under the registry lock, so the engine can iterate the fleet without holding
// any registry mutex or reaching into Provider internals.
type ProviderSnapshot struct {
	ID             string
	ProviderKey    string // base64 X25519 public key — earnings/session identity
	SerialNumber   string
	HardwareModel  string // SE-signed Apple model id (e.g. "Mac15,8"); "" if unattested
	MemoryGB       int    // self-reported unified memory (Phase 0 tier source)
	TrustLevel     TrustLevel
	Attested       bool
	Online         bool    // status is online (not offline/untrusted)
	ModelLoaded    bool    // an advertised model is currently loaded for routing
	CurrentModel   string  // model currently loaded/served; "" if none
	MemoryPressure float64 // live system metric (0..1)
	ThermalState   string  // nominal/fair/serious/critical
}

// ListProviders returns a read-only snapshot of every connected provider. It is
// safe to call from outside the registry: each entry is a value copy taken under
// the registry read lock and the per-provider lock, so callers never observe a
// live Provider. Behavior-preserving — it mutates nothing.
func (r *Registry) ListProviders() []ProviderSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()

	out := make([]ProviderSnapshot, 0, len(r.providers))
	for _, p := range r.providers {
		p.mu.Lock()
		serial := ""
		hardwareModel := ""
		if p.AttestationResult != nil {
			serial = p.AttestationResult.SerialNumber
			hardwareModel = p.AttestationResult.HardwareModel
		}
		warm := r.warmServingModelLocked(p)
		out = append(out, ProviderSnapshot{
			ID:             p.ID,
			ProviderKey:    p.PublicKey,
			SerialNumber:   serial,
			HardwareModel:  hardwareModel,
			MemoryGB:       p.Hardware.MemoryGB,
			TrustLevel:     p.TrustLevel,
			Attested:       p.Attested,
			Online:         p.Status == StatusOnline || p.Status == StatusServing,
			ModelLoaded:    warm != "",
			CurrentModel:   warm,
			MemoryPressure: p.SystemMetrics.MemoryPressure,
			ThermalState:   p.SystemMetrics.ThermalState,
		})
		p.mu.Unlock()
	}
	return out
}

// warmServingModelLocked returns a model that is both loaded and currently
// eligible for routing. Raw heartbeat inventory remains on Provider, but cannot
// earn base rewards after a catalog capability change. Caller holds r.mu and
// p.mu.
func (r *Registry) warmServingModelLocked(p *Provider) string {
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slotStateModelLoaded(slot.State) &&
				r.providerServesRoutableModelLocked(p, slot.Model, false) {
				return slot.Model
			}
		}
		return ""
	}
	if p.CurrentModel != "" &&
		r.providerServesRoutableModelLocked(p, p.CurrentModel, false) {
		return p.CurrentModel
	}
	for _, modelID := range p.WarmModels {
		if r.providerServesRoutableModelLocked(p, modelID, false) {
			return modelID
		}
	}
	return ""
}

// PublicProviderModelSnapshot is the capability-filtered model view exposed by
// public provider/statistics surfaces.
type PublicProviderModelSnapshot struct {
	Models       []string
	CurrentModel string
}

// PublicProviderModels returns detached, live catalog-eligible model state for
// each connected provider. Catalog hot changes are reflected without rewriting
// the provider's raw inventory.
func (r *Registry) PublicProviderModels() map[string]PublicProviderModelSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]PublicProviderModelSnapshot, len(r.providers))

	// Every provider's eligible model IDs share ONE backing array instead of
	// one slice allocation per provider: at fleet scale (~1,260 providers) the
	// per-provider allocations were the entire cost of this walk, paid as GC
	// pressure by /v1/stats and /v1/providers/attestation. Each provider's view
	// is a 3-index sub-slice (cap == len), so a consumer append can never write
	// into a neighbour's entries. The size pass is only a hint — p.Models is
	// replaced copy-on-write and may grow between the two passes; append then
	// reallocates, and views already handed out keep their (unchanged) old
	// array. A provider with no eligible model still gets a non-nil empty slice:
	// stats serializes it straight to JSON and must emit [] rather than null.
	total := 0
	for _, p := range r.providers {
		p.mu.Lock()
		total += len(p.Models)
		p.mu.Unlock()
	}
	buf := make([]string, 0, total)

	for id, p := range r.providers {
		p.mu.Lock()
		start := len(buf)
		current := ""
		for _, model := range p.Models {
			if !r.providerModelAllowedByCatalogLocked(p, model) {
				continue
			}
			buf = append(buf, model.ID)
			// The current model is exposed only when the provider advertises it
			// as a catalog-eligible entry — the same predicate as the filter.
			if p.CurrentModel != "" && model.ID == p.CurrentModel {
				current = p.CurrentModel
			}
		}
		end := len(buf)
		p.mu.Unlock()
		out[id] = PublicProviderModelSnapshot{
			Models:       buf[start:end:end],
			CurrentModel: current,
		}
	}
	return out
}

// TrustMeetsMinimum reports whether a trust level satisfies the registry's
// configured MinTrustLevel. Exported, read-only helper for the base-rewards
// eligibility gate (which must apply the same trust floor as routing).
func (r *Registry) TrustMeetsMinimum(level TrustLevel) bool {
	return trustRank(level) >= trustRank(r.MinTrustLevel)
}
