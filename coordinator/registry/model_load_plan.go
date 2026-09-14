package registry

import "time"

func (r *Registry) planModelLoadActions(queuedModels []string, now time.Time) []modelLoadAction {
	r.mu.RLock()
	defer r.mu.RUnlock()

	selectedProviders := make(map[string]struct{})
	actions := make([]modelLoadAction, 0, len(queuedModels))
	for _, model := range queuedModels {
		if r.hasWarmProviderLocked(model, now) {
			continue
		}

		providerID := r.bestModelLoadProviderLocked(model, now, selectedProviders)
		if providerID == "" {
			continue
		}
		selectedProviders[providerID] = struct{}{}
		actions = append(actions, modelLoadAction{providerID: providerID, modelID: model})
	}
	return actions
}

// hasWarmProviderLocked reports whether a connected provider already has the
// model warm. Caller must hold r.mu (read or write).
func (r *Registry) hasWarmProviderLocked(model string, now time.Time) bool {
	// Only advertisers can hold the model warm (warm/slot reports are
	// canonicalized against p.Models; providerHasWarmModelLocked also requires
	// providerServesRoutableModelLocked), so the per-model index prunes the
	// walk losslessly (model_index.go).
	for _, p := range r.providersForModelLocked(model) {
		p.mu.Lock()
		warm := r.providerHasWarmModelLocked(p, model, now)
		p.mu.Unlock()
		if warm {
			return true
		}
	}
	return false
}

// providerHasWarmModelLocked checks whether the provider has the model warm
// AND passes the same routing safety gates used by the scheduler. A provider
// with stale attestation or failed privacy checks should not suppress swap
// planning. Caller must hold p.mu. Caller must hold r.mu (read or write).
func (r *Registry) providerHasWarmModelLocked(p *Provider, model string, now time.Time) bool {
	// Liveness/trust/privacy core, with NO owner relaxation: private-only
	// providers serve only their owner's self-route traffic, never the public
	// fleet, and must not suppress public swap planning — otherwise a
	// private-only machine that happens to hold a queued public model warm makes
	// the planner believe the model is already served and skip load_model to an
	// eligible public node, stranding public requests until queue timeout.
	if !r.providerLivenessGateLocked(p, r.MinTrustLevel, false, now) {
		return false
	}
	// Catalog membership + dedicated-box isolation: for a dedicated-family model
	// (e.g. Gemma 4), a warm mixed-catalog box is not a usable warm provider —
	// routing won't send the model there. Treat it as not warm so it neither
	// suppresses cold-spill/swap planning onto a real dedicated box nor counts
	// toward the model's warm-capacity demand target.
	if !r.providerServesRoutableModelLocked(p, model, false) {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model {
				// BackendCapacity is authoritative when present.
				// Only "running" and "idle" mean the model is warm.
				return slot.State == "running" || slot.State == "idle"
			}
		}
		// Model has no slot in BackendCapacity -- it's not loaded.
		return false
	}
	// Legacy provider without BackendCapacity: fall back to WarmModels.
	for _, warmModel := range p.WarmModels {
		if warmModel == model {
			return true
		}
	}
	return false
}

// bestModelLoadProviderLocked selects the eligible provider with the fewest
// pending requests. Caller must hold r.mu (read or write).
func (r *Registry) bestModelLoadProviderLocked(model string, now time.Time, selectedProviders map[string]struct{}) string {
	bestProviderID := ""
	// Only advertisers qualify (modelLoadCandidatePendingLocked requires
	// providerServesRoutableModelLocked), so the per-model index prunes the
	// walk losslessly (model_index.go).
	for _, p := range r.providersForModelLocked(model) {
		id := p.ID
		if _, selected := selectedProviders[id]; selected {
			continue
		}
		// Skip providers that have any pending model load -- sending a
		// second load_model while the first is in progress can cause
		// swap oscillation on single-slot providers.
		if r.providerHasPendingLoad(id) {
			continue
		}

		pendingCount, ok := r.modelLoadCandidatePendingLocked(p, model, now)
		if !ok {
			continue
		}
		// Only consider idle providers (no in-flight requests). Sending
		// load_model to a provider that is actively serving another model
		// will fail because the active slot cannot be evicted.
		if pendingCount == 0 {
			bestProviderID = id
			break
		}
	}
	return bestProviderID
}

// modelLoadCandidatePendingLocked applies the same routing safety gates used by
// the scheduler, then returns the provider's current pending request count.
// Caller must hold r.mu (read or write).
func (r *Registry) modelLoadCandidatePendingLocked(p *Provider, model string, now time.Time) (int, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Liveness/trust/privacy core + catalog membership + dedicated-box
	// isolation, with NO owner relaxation: this is a public load_model target
	// picker, so private-only machines never qualify and a dedicated-family
	// model (e.g. Gemma 4) may only be loaded onto a provider dedicated to it,
	// never a mixed-catalog box (routing would never use it). Mirrors
	// providerHasWarmModelLocked.
	if !r.providerLivenessGateLocked(p, r.MinTrustLevel, false, now) {
		return 0, false
	}
	if !r.providerServesRoutableModelLocked(p, model, false) {
		return 0, false
	}

	// Memory gate: reject providers that cannot run the model per the catalog's
	// authoritative min_ram_gb (falling back to the weight heuristic only when
	// unknown). Shares modelFitsHardware with the consumer-routing admission
	// gate so the two can never drift. This prevents the coordinator from
	// sending load_model commands to machines that clearly cannot fit it, while
	// trusting the operator-published requirement rather than a synthetic
	// multiple that would exclude catalog-qualified nodes.
	if entry, ok := r.modelCatalog[model]; ok && (entry.MinRAMGB > 0 || entry.SizeGB > 0) {
		if !modelFitsHardware(entry.MinRAMGB, entry.SizeGB, float64(p.Hardware.MemoryGB)) {
			return 0, false
		}
		// Live free-capacity gate (shared helper with the direct path): don't plan
		// a load the provider already reports it cannot fit. Mirrors freeMemoryAdmits
		// so the warming planner can't send a load_model the provider then
		// OOM-rejects, which would leave queued cold-dispatch requests sitting until
		// they time out. Legacy providers (no report) fall through to the static gate.
		if admit, reported := reportedFreeForLoadAdmits(entry.SizeGB, backendFreeForLoadGB(p.BackendCapacity)); reported && !admit {
			return 0, false
		}
	}

	return p.pendingCount(), true
}
