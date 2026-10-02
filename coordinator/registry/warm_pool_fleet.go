package registry

import (
	"sort"
	"time"
)

func (r *Registry) warmPoolFleetSnapshot(now time.Time) map[string]warmPoolModelSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]warmPoolModelSnapshot)
	// Per-model rate samples (from every eligible provider serving the model,
	// warm or warmable) collapsed to a representative median at the end.
	// decodeSamples carries the quality-cap solo rate (→ qualityConcurrency);
	// serviceSamples the observed-EWMA service rate (→ E[S]).
	decodeSamples := make(map[string][]float64)
	serviceSamples := make(map[string][]float64)
	prefillSamples := make(map[string][]float64)
	concSamples := make(map[string][]float64)
	qualitySamples := make(map[string][]float64)
	aggregateSamples := make(map[string][]float64)
	params := warmTargetParams{LoadFactorK: effectiveTPSLoadFactor, FallbackQualityConcurrency: 1}
	if r.warmPool != nil {
		params = r.warmPool.targetParams()
	}
	for _, p := range r.providers {
		p.mu.Lock()
		models := make([]string, 0, len(p.Models))
		for _, m := range p.Models {
			if r.providerModelAllowedByCatalogLocked(p, m) {
				models = append(models, m.ID)
			}
		}
		for _, model := range models {
			warm := r.providerHasWarmModelLocked(p, model, now)
			if warm {
				s := out[model]
				s.model = model
				s.warm++
				running, waiting := warmPoolModelLoadLocked(p, model)
				s.running += running
				s.waiting += waiting
				if !r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model) || warmPoolBackendSlotBusyLocked(p) {
					s.warmSaturated++
					// Saturated while serving NONE of this model's requests means
					// a co-resident model is holding the capacity. That load is
					// invisible in s.running/s.waiting, so the warm-pool target
					// must not treat this provider as usable capacity for this
					// model (see headroomTarget).
					if running+waiting == 0 {
						s.warmForeignBlocked++
					}
				}
				out[model] = s
				// decodeSamples feed soloDecodeTPS → qualityConcurrency in the
				// warm target. Use the SAME solo resolver as the admission cap
				// (solo median / seed → provider benchmark), NOT the per-slot
				// observed EWMA: the EWMA is a contended rate, and planning warm
				// targets from it while admission caps from the solo rate would
				// let the two disagree. The observed-EWMA chain
				// (resolvedModelTPSLocked) still feeds serviceSamples/prefill —
				// E[S] wants the load-inclusive rate a request actually sees.
				serviceTPS, _ := resolvedModelTPSLocked(p, model)
				quality, aggregate, prefillTPS := r.warmPoolCapacityLocked(p, model, params)
				qualitySamples[model] = append(qualitySamples[model], float64(quality))
				aggregateSamples[model] = append(aggregateSamples[model], aggregate)
				decodeSamples[model] = append(decodeSamples[model], r.resolvedSoloModelTPSLocked(p, model).tps)
				serviceSamples[model] = append(serviceSamples[model], serviceTPS)
				prefillSamples[model] = append(prefillSamples[model], prefillTPS)
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
				continue
			}
			candidate, reason := r.warmPoolCandidateReasonLocked(p, model, now)
			s := out[model]
			s.model = model
			if reason == warmColdEligible {
				s.eligibleCold = append(s.eligibleCold, candidate)
				out[model] = s
				// Same solo-resolver / service-rate split as the warm branch above.
				serviceTPS, _ := resolvedModelTPSLocked(p, model)
				quality, aggregate, prefillTPS := r.warmPoolCapacityLocked(p, model, params)
				qualitySamples[model] = append(qualitySamples[model], float64(quality))
				aggregateSamples[model] = append(aggregateSamples[model], aggregate)
				decodeSamples[model] = append(decodeSamples[model], r.resolvedSoloModelTPSLocked(p, model).tps)
				serviceSamples[model] = append(serviceSamples[model], serviceTPS)
				prefillSamples[model] = append(prefillSamples[model], prefillTPS)
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
			} else {
				if s.coldDisq == nil {
					s.coldDisq = make(map[warmColdReason]int)
				}
				s.coldDisq[reason]++
				s.coldIneligible++
				out[model] = s
			}
		}
		p.mu.Unlock()
	}
	for model, s := range out {
		sort.Slice(s.eligibleCold, func(i, j int) bool {
			a, b := s.eligibleCold[i], s.eligibleCold[j]
			if a.recentResidentModels != b.recentResidentModels {
				return a.recentResidentModels < b.recentResidentModels
			}
			if a.score != b.score {
				return a.score > b.score
			}
			return a.providerID < b.providerID
		})
		s.soloDecodeTPS = medianFloat(decodeSamples[model])
		s.serviceDecodeTPS = medianFloat(serviceSamples[model])
		s.prefillTPS = medianFloat(prefillSamples[model])
		s.maxProviderConc = int(medianFloat(concSamples[model]))
		s.qualityConc = max(1, int(medianFloat(qualitySamples[model])))
		s.aggregateDecodeTPS = medianFloat(aggregateSamples[model])
		out[model] = s
	}
	return out
}

// warmPoolModelLoadLocked returns the in-flight (NumRunning) and provider-queued
// (NumWaiting) request counts for the model on this provider, read from the
// authoritative BackendCapacity slot. Caller must hold p.mu.
func warmPoolModelLoadLocked(p *Provider, model string) (running, waiting int) {
	if p.BackendCapacity == nil {
		return 0, 0
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model {
			return slot.NumRunning, slot.NumWaiting
		}
	}
	return 0, 0
}

// warmColdReason labels why a cold (on-disk, not-warm) provider is or isn't an
// eligible warm-pool target. Empty ("") means eligible. Used to instrument why
// the eligible-cold set is smaller than the raw cold-provider count (e.g. a
// dedicated pool reporting many cold boxes but warming few) — counts only, no
// provider identities, so it is privacy-safe to log/expose.
type warmColdReason string

const (
	warmColdEligible       warmColdReason = ""
	warmColdOfflineUntrust warmColdReason = "offline_untrusted_private"
	warmColdPendingLoad    warmColdReason = "pending_load_or_cooldown"
	warmColdNotIdle        warmColdReason = "not_idle"
	warmColdThermal        warmColdReason = "thermal_critical"
	warmColdTrust          warmColdReason = "trust_or_runtime"
	warmColdStaleChallenge warmColdReason = "stale_challenge"
	warmColdNotServing     warmColdReason = "not_serving_catalog"
	warmColdDedicated      warmColdReason = "dedicated_excluded"
	warmColdTooLarge       warmColdReason = "model_too_large"
	warmColdNoFreeForLoad  warmColdReason = "no_free_for_load"
	warmColdStateRestoring warmColdReason = "state_restoring"
	warmColdDwell          warmColdReason = "placement_dwell"
	warmColdAutopilot      warmColdReason = "autopilot_managed"
)

// warmColdReasonStrings converts a reason tally to a string-keyed map for
// logging / the snapshot. Returns nil for an empty tally.
func warmColdReasonStrings(in map[warmColdReason]int) map[string]int {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]int, len(in))
	for reason, n := range in {
		out[string(reason)] = n
	}
	return out
}

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
	if providerLegacyModelChangesBlockedLocked(p) {
		return warmPoolCandidate{}, warmColdAutopilot
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted || p.PrivateOnly {
		return warmPoolCandidate{}, warmColdOfflineUntrust
	}
	if providerStateRestoreRequiredLocked(p) {
		return warmPoolCandidate{}, warmColdStateRestoring
	}
	if r.providerHasPendingLoad(p.ID) || now.Before(p.modelLoadSendRetryAt) || r.gateOf(p).dispatchLoadCooled(model, now) {
		return warmPoolCandidate{}, warmColdPendingLoad
	}
	if r.warmPool != nil && r.warmPool.config.MinDwell > 0 && !p.lastWarmPlacementAt.IsZero() && now.Sub(p.lastWarmPlacementAt) < r.warmPool.config.MinDwell {
		return warmPoolCandidate{}, warmColdDwell
	}
	if providerDrainingLocked(p, now) || p.pendingCount() != 0 || warmPoolBackendSlotBusyLocked(p) {
		return warmPoolCandidate{}, warmColdNotIdle
	}
	if p.SystemMetrics.ThermalState == "critical" {
		return warmPoolCandidate{}, warmColdThermal
	}
	if !r.providerTrustMeetsMinimumAtLocked(p, r.MinTrustLevel, now) || !p.RuntimeVerified || !r.providerSupportsPrivateTextLocked(p) {
		return warmPoolCandidate{}, warmColdTrust
	}
	if !r.providerChallengeFreshAtLocked(p, now) {
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
	if admit, reported := reportedFreeForLoadAdmitsWithOffload(r.catalogSizeGBLocked(model), advertisedOffloadedMemoryGBLocked(p, model, r.catalogSizeGBLocked(model)), backendFreeForLoadGB(p.BackendCapacity)); reported && !admit {
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
	recent := 0
	if r.warmPool != nil && r.warmPool.config.MinDwell > 0 {
		for resident, work := range p.warmWorkCounters {
			if resident != model && !work.lastWorkAt.IsZero() && now.Sub(work.lastWorkAt) < r.warmPool.config.MinDwell {
				recent++
			}
		}
	}
	return warmPoolCandidate{providerID: p.ID, score: score, recentResidentModels: recent}, warmColdEligible
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

func (r *Registry) pendingModelLoadCount(now time.Time) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	count := 0
	for key, expiresAt := range r.pendingModelLoads {
		if now.After(expiresAt) {
			r.recordDeadlineLoadActivityLocked(key.ProviderID, now)
			delete(r.pendingModelLoads, key)
			delete(r.pendingModelLoadStarted, key)
			continue
		}
		count++
	}
	return count
}
