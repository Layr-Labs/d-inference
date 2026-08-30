package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// ProviderSnapshot is a flat, read-only view of the per-provider fields the
// base-rewards engine needs to build settlement candidates. It is a copy taken
// under the registry lock, so the engine can iterate the fleet without holding
// any registry mutex or reaching into Provider internals.
type ProviderSnapshot struct {
	ID                      string
	ProviderKey             string // base64 X25519 public key — earnings/session identity
	SerialNumber            string
	HardwareModel           string // SE-signed Apple model id (e.g. "Mac15,8"); "" if unattested
	MemoryGB                int    // self-reported unified memory (Phase 0 tier source)
	TrustLevel              TrustLevel
	Attested                bool
	Online                  bool    // status is online (not offline/untrusted)
	ModelLoaded             bool    // an advertised model is currently loaded for routing
	CurrentModel            string  // model currently loaded/served; "" if none
	MemoryPressure          float64 // live system metric (0..1)
	ThermalState            string  // nominal/fair/serious/critical
	UpdateLifecycleReported bool
	UpdateLifecycleState    string
	WarmIntent              protocol.WarmIntent
	UpdateDesiredGeneration uint64
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
			ID:                      p.ID,
			ProviderKey:             p.PublicKey,
			SerialNumber:            serial,
			HardwareModel:           hardwareModel,
			MemoryGB:                p.Hardware.MemoryGB,
			TrustLevel:              p.TrustLevel,
			Attested:                p.Attested,
			Online:                  p.Status == StatusOnline || p.Status == StatusServing,
			ModelLoaded:             warm != "",
			CurrentModel:            warm,
			MemoryPressure:          p.SystemMetrics.MemoryPressure,
			ThermalState:            p.SystemMetrics.ThermalState,
			UpdateLifecycleReported: p.UpdateLifecycleReported,
			UpdateLifecycleState:    p.UpdateLifecycleState,
			WarmIntent:              p.WarmIntent,
			UpdateDesiredGeneration: p.UpdateDesiredGeneration,
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
	for id, p := range r.providers {
		p.mu.Lock()
		snapshot := PublicProviderModelSnapshot{
			Models: make([]string, 0, len(p.Models)),
		}
		for _, model := range p.Models {
			if r.providerModelAllowedByCatalogLocked(p, model) {
				snapshot.Models = append(snapshot.Models, model.ID)
			}
		}
		if p.CurrentModel != "" &&
			r.providerServesCatalogModelLocked(p, p.CurrentModel) {
			snapshot.CurrentModel = p.CurrentModel
		}
		p.mu.Unlock()
		out[id] = snapshot
	}
	return out
}

// TrustMeetsMinimum reports whether a trust level satisfies the registry's
// configured MinTrustLevel. Exported, read-only helper for the base-rewards
// eligibility gate (which must apply the same trust floor as routing).
func (r *Registry) TrustMeetsMinimum(level TrustLevel) bool {
	return trustRank(level) >= trustRank(r.MinTrustLevel)
}
