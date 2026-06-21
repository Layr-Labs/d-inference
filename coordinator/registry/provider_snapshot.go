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
		warm := warmServingModel(p)
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

// warmServingModel returns the model that counts as "loaded for routing" for
// base-rewards eligibility, using the authoritative backend slot state
// when present (a slot is warm only in "running"/"idle", matching the scheduler
// at registry.go's warm check), so a crashed/reloading/idle_shutdown slot with
// stale legacy fields is NOT treated as serving. Falls back to the reported
// CurrentModel/WarmModels only for legacy providers that send no BackendCapacity.
// Caller must hold p.mu.
func warmServingModel(p *Provider) string {
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if (slot.State == "running" || slot.State == "idle") && slot.Model != "" {
				return slot.Model
			}
		}
		return "" // BackendCapacity present but no warm slot → nothing serving
	}
	if p.CurrentModel != "" {
		return p.CurrentModel
	}
	if len(p.WarmModels) > 0 {
		return p.WarmModels[0]
	}
	return ""
}

// TrustMeetsMinimum reports whether a trust level satisfies the registry's
// configured MinTrustLevel. Exported, read-only helper for the base-rewards
// eligibility gate (which must apply the same trust floor as routing).
func (r *Registry) TrustMeetsMinimum(level TrustLevel) bool {
	return trustRank(level) >= trustRank(r.MinTrustLevel)
}
