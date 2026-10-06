package registry

import "time"

// ModelLoadPreparation holds the fleet read lease while evaluating load targets.
// It exposes only decisions; each evaluation reads live provider state under its
// original provider lock. Call Close after use, not concurrently with evaluation.
type ModelLoadPreparation struct {
	registry *Registry
	closed   bool
}

func (p *ModelLoadPlanner) Prepare() *ModelLoadPreparation {
	p.registry.mu.RLock()
	return &ModelLoadPreparation{registry: p.registry}
}

func (p *ModelLoadPreparation) Close() {
	if p != nil && !p.closed {
		p.closed = true
		p.registry.mu.RUnlock()
	}
}

// Candidate applies routing safety and load-memory gates, without excluding an
// otherwise eligible provider just because it currently owns requests.
func (s *ModelLoadPreparation) Candidate(providerID, model string, now time.Time) (int, bool) {
	if s == nil || s.closed {
		return 0, false
	}
	r := s.registry
	p := r.providers[providerID]
	if p == nil {
		return 0, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if providerLegacyModelChangesBlockedLocked(p) || !p.warmLifecycleLocked().CanLoad(now) {
		return 0, false
	}

	// This is a public load target, with no owner relaxation. Private-only and
	// mixed-catalog dedicated-model providers cannot qualify for public demand.
	if providerDrainingLocked(p, now) || !r.providerLivenessGateLocked(p, r.MinTrustLevel, false, now) {
		return 0, false
	}
	if !r.providerServesRoutableModelLocked(p, model, false) {
		return 0, false
	}

	// Use the same catalog and reported free-capacity bounds as direct routing;
	// planning must not reserve loads the provider will reject for memory.
	if entry, ok := r.modelCatalog[model]; ok && (entry.MinRAMGB > 0 || entry.SizeGB > 0) {
		if !modelFitsHardware(entry.MinRAMGB, entry.SizeGB, float64(p.Hardware.MemoryGB)) {
			return 0, false
		}
		if admit, reported := reportedFreeForLoadAdmitsWithOffload(entry.SizeGB, advertisedOffloadedMemoryGBLocked(p, model, entry.SizeGB), backendFreeForLoadGB(p.BackendCapacity)); reported && !admit {
			return 0, false
		}
	}

	return p.pendingCount(), true
}

// bestProvider selects an eligible idle advertiser that has no pending load.
func (s *ModelLoadPreparation) bestProvider(model string, now time.Time, selectedProviders map[string]struct{}) string {
	r := s.registry
	bestProviderID := ""
	for _, p := range r.providersForModelLocked(model) {
		id := p.ID
		if _, selected := selectedProviders[id]; selected {
			continue
		}
		// Multiple simultaneous load commands can cause swap oscillation on a
		// single-slot provider, even when they target different models.
		if r.providerHasPendingLoad(id) {
			continue
		}

		pendingCount, ok := s.Candidate(id, model, now)
		if !ok {
			continue
		}
		if pendingCount == 0 {
			bestProviderID = id
			break
		}
	}
	return bestProviderID
}
