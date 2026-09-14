package registry

import (
	"time"
)

func (r *Registry) warmPoolCandidateLocked(p *Provider, model string, now time.Time) (warmPoolCandidate, bool) {
	c, reason := r.warmPoolCandidateReasonLocked(p, model, now)
	return c, reason == warmColdEligible
}

// warmPoolCandidateReasonLocked is warmPoolCandidateLocked with the
// disqualification reason exposed for instrumentation. Caller holds r.mu + p.mu.
//
// This is intentionally NOT folded onto providerLivenessGateLocked /
// providerServesRoutableModelLocked (unlike the other four eligibility gates):
// it returns a granular per-gate reason label (exposed in the warm-pool
// snapshot/metrics), so the liveness checks must stay split across their
// distinct reason buckets (warmColdOfflineUntrust / warmColdTrust /
// warmColdStaleChallenge / warmColdNotServing / warmColdDedicated) rather than
// collapse into one boolean. It also interleaves warm-pool-specific gates
// (pending-load, not-idle, thermal-critical, model-too-large, free-for-load)
// between those buckets, in an order that determines which reason wins. Reusing
// the boolean helpers here would change the reported reason mix — a behavior
// change — so the checks are kept inline.
func (r *Registry) warmPoolCandidateReasonLocked(p *Provider, model string, now time.Time) (warmPoolCandidate, warmColdReason) {
	if p.Status == StatusOffline || p.Status == StatusUntrusted || p.PrivateOnly {
		return warmPoolCandidate{}, warmColdOfflineUntrust
	}
	if providerStateRestoreRequiredLocked(p) {
		return warmPoolCandidate{}, warmColdStateRestoring
	}
	if r.providerHasPendingLoad(p.ID) || r.gateOf(p).dispatchLoadCooled(model, now) {
		return warmPoolCandidate{}, warmColdPendingLoad
	}
	if p.pendingCount() != 0 || warmPoolBackendSlotBusyLocked(p) {
		return warmPoolCandidate{}, warmColdNotIdle
	}
	if p.SystemMetrics.ThermalState == "critical" {
		return warmPoolCandidate{}, warmColdThermal
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) || !p.RuntimeVerified || !r.providerSupportsPrivateTextLocked(p) {
		return warmPoolCandidate{}, warmColdTrust
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return warmPoolCandidate{}, warmColdStaleChallenge
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return warmPoolCandidate{}, warmColdNotServing
	}
	// Don't pre-warm a dedicated-family model (e.g. Gemma 4) onto a non-dedicated
	// (mixed-catalog) box: routing will never send the model there, so the warm
	// would be wasted GPU memory and would mislead the demand calc into thinking
	// the model is already covered. Mirrors the routing/preflight gate.
	if r.providerExcludedByDedicatedRuleLocked(p, model) {
		return warmPoolCandidate{}, warmColdDedicated
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
		return warmPoolCandidate{}, warmColdTooLarge
	}
	// Live free-capacity gate (shared helper with the direct/planner paths): don't
	// pick a warm-pool target the provider already reports it cannot fit, or the
	// warm pool issues a load_model the provider rejects (failed warm + pending-load
	// cooldown) instead of choosing a truly loadable node (#390).
	if admit, reported := reportedFreeForLoadAdmits(r.catalogSizeGBLocked(model), backendFreeForLoadGB(p.BackendCapacity)); reported && !admit {
		return warmPoolCandidate{}, warmColdNoFreeForLoad
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
	return warmPoolCandidate{ProviderID: p.ID, Score: score}, warmColdEligible
}

func warmPoolBackendSlotBusyLocked(p *Provider) bool {
	if p.BackendCapacity == nil {
		return false
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.NumRunning > 0 || slot.NumWaiting > 0 {
			return true
		}
	}
	return false
}
