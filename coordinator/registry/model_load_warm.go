package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

// Warm reports usable public residency while retaining the planning lease.
func (s *ModelLoadPreparation) Warm(providerID, model string, now time.Time) bool {
	if s == nil || s.closed {
		return false
	}
	p := s.registry.providers[providerID]
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return s.warmLocked(p, model, now)
}

// ColdCandidate evaluates a proactive placement target independently of whether
// it already holds the model warm. Fleet collection decides when a load is needed.
func (s *ModelLoadPreparation) ColdCandidate(providerID, model string, now time.Time) (warmplan.Candidate, warmplan.ColdReason) {
	if s == nil || s.closed {
		return warmplan.Candidate{}, warmplan.WarmColdOfflineUntrust
	}
	p := s.registry.providers[providerID]
	if p == nil {
		return warmplan.Candidate{}, warmplan.WarmColdOfflineUntrust
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return s.coldCandidateLocked(p, model, now)
}

// warmLocked requires the planning lease and p.mu.
func (s *ModelLoadPreparation) warmLocked(p *Provider, model string, now time.Time) bool {
	r := s.registry
	if providerAutopilotTransitionLocked(p) {
		return false
	}
	// Liveness/trust/privacy core, with NO owner relaxation: private-only
	// providers serve only their owner's self-route traffic, never the public
	// fleet, and must not suppress public swap planning. Otherwise a private-only
	// machine holding a queued public model warm strands public requests.
	if providerDrainingLocked(p, now) || !r.providerLivenessGateLocked(p, r.MinTrustLevel, false, now) {
		return false
	}
	// A warm mixed-catalog box cannot cover demand for a dedicated-family model:
	// routing will not send it requests, so it must not suppress load planning.
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
		// Model has no slot in BackendCapacity -- it is not loaded.
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

// coldCandidateLocked requires the planning lease and p.mu. Keep the gates in
// this order: the first failure determines the reported disqualification reason.
// In particular, folding liveness/catalog/dedication into the routing helpers
// would lose the distinct warm-pool reason buckets and interleaved load gates.
func (s *ModelLoadPreparation) coldCandidateLocked(p *Provider, model string, now time.Time) (warmplan.Candidate, warmplan.ColdReason) {
	r := s.registry
	if providerLegacyModelChangesBlockedLocked(p) {
		return warmplan.Candidate{}, warmplan.WarmColdAutopilot
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted || p.PrivateOnly {
		return warmplan.Candidate{}, warmplan.WarmColdOfflineUntrust
	}
	if providerStateRestoreRequiredLocked(p) {
		return warmplan.Candidate{}, warmplan.WarmColdStateRestoring
	}
	if r.providerHasPendingLoad(p.ID) || !p.warmLifecycleLocked().CanLoad(now) || r.gateOf(p).dispatchLoadCooled(model, now) {
		return warmplan.Candidate{}, warmplan.WarmColdPendingLoad
	}
	if r.warmPool != nil && p.warmLifecycleLocked().DwellActive(now, r.warmPool.config.MinDwell) {
		return warmplan.Candidate{}, warmplan.WarmColdDwell
	}
	if providerDrainingLocked(p, now) || p.pendingCount() != 0 || warmPoolBackendSlotBusyLocked(p) {
		return warmplan.Candidate{}, warmplan.WarmColdNotIdle
	}
	if p.SystemMetrics.ThermalState == "critical" {
		return warmplan.Candidate{}, warmplan.WarmColdThermal
	}
	if !r.providerTrustMeetsMinimumAtLocked(p, r.MinTrustLevel, now) || !p.RuntimeVerified || !r.providerSupportsPrivateTextLocked(p) {
		return warmplan.Candidate{}, warmplan.WarmColdTrust
	}
	if !r.providerChallengeFreshAtLocked(p, now) {
		return warmplan.Candidate{}, warmplan.WarmColdStaleChallenge
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return warmplan.Candidate{}, warmplan.WarmColdNotServing
	}
	// Do not pre-warm a dedicated-family model onto a mixed-catalog box:
	// routing will never use it, and it would falsely cover demand.
	if r.providerExcludedByDedicatedRuleLocked(p, model) {
		return warmplan.Candidate{}, warmplan.WarmColdDedicated
	}
	totalMemoryGB := float64(p.Hardware.MemoryGB)
	gpuActiveGB := 0.0
	if p.BackendCapacity != nil {
		if p.BackendCapacity.TotalMemoryGB > 0 {
			totalMemoryGB = p.BackendCapacity.TotalMemoryGB
		}
		gpuActiveGB = p.BackendCapacity.GPUMemoryActiveGB
	}
	if !modelFitsHardware(r.catalogMinRAMGbLocked(model), r.catalogSizeGBLocked(model), totalMemoryGB) {
		return warmplan.Candidate{}, warmplan.WarmColdTooLarge
	}
	// Use the same live free-capacity gate as direct loading and planning so a
	// rejected placement cannot strand demand behind the pending-load cooldown.
	if admit, reported := reportedFreeForLoadAdmitsWithOffload(r.catalogSizeGBLocked(model), advertisedOffloadedMemoryGBLocked(p, model, r.catalogSizeGBLocked(model)), backendFreeForLoadGB(p.BackendCapacity)); reported && !admit {
		return warmplan.Candidate{}, warmplan.WarmColdNoFreeForLoad
	}
	freeGB := totalMemoryGB - gpuActiveGB
	if freeGB < 0 {
		freeGB = 0
	}
	thermalPenalty := 0.0
	switch p.SystemMetrics.ThermalState {
	case "serious":
		thermalPenalty = 1000
	case "fair":
		thermalPenalty = 250
	}
	score := freeGB*100 + resolvedDecodeTPS(p)*10 - p.SystemMetrics.MemoryPressure*500 - p.SystemMetrics.CPUUsage*100 - thermalPenalty
	recent := 0
	if r.warmPool != nil && r.warmPool.config.MinDwell > 0 {
		recent = p.warmWork.RecentOther(model, now, r.warmPool.config.MinDwell)
	}
	return warmplan.Candidate{ProviderID: p.ID, Score: score, RecentResidentModels: recent}, warmplan.WarmColdEligible
}
