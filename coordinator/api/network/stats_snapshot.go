package network

import (
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// computeStats returns core stats with the latest independently refreshed
// geography. Core query failures prevent publication; geography failures are
// represented explicitly and never block the core snapshot.
func (s *Controller) computeStats() ([]byte, error) {
	// Preserve the start of the source observation through successful cache hits
	// and bounded stale-on-error reads; downstream caches must not renew its age.
	snapshotAt := time.Now()
	var (
		totalRequests    int64
		totalTokensGen   int64
		totalGPUCores    int
		totalCPUCores    int
		totalMemoryGB    int
		totalBandwidthGB float64
		providers        []map[string]any
		modelMap         = map[string]int{} // model ID → provider count
		activePowerWatts float64            // sum of estimated watts over online public providers
	)

	publicProviderModels := s.registry().PublicProviderModels()
	s.registry().ForEachProvider(func(p *registry.Provider) {
		// Private-only providers serve only their owner's self-route traffic and
		// are not part of the public fleet, so they must not inflate public
		// totals, provider counts, per-model provider counts, or active power.
		if p.PrivateOnly {
			return
		}
		activePowerWatts += registry.EstimateMachineWatts(p.Hardware.ChipFamily, p.Hardware.ChipTier, p.Hardware.GPUCores)
		totalRequests += p.Stats.RequestsServed
		totalTokensGen += p.Stats.TokensGenerated
		totalGPUCores += p.Hardware.GPUCores
		totalCPUCores += p.Hardware.CPUCores.Total
		totalMemoryGB += p.Hardware.MemoryGB
		totalBandwidthGB += p.Hardware.MemoryBandwidthGBs

		status := string(p.Status)
		if status == "" {
			status = "online"
		}

		// Use the registry's capability-filtered provider snapshot so a catalog
		// hot change cannot leave an ineligible pair on the public stats feed.
		modelSnapshot := publicProviderModels[p.ID]
		provModels := modelSnapshot.Models

		lastChallengeVerified := ""
		if last := p.GetLastChallengeVerified(); !last.IsZero() {
			lastChallengeVerified = last.UTC().Format(time.RFC3339)
		}

		prov := map[string]any{
			"id":                             p.ID,
			"chip":                           p.Hardware.ChipName,
			"chip_family":                    p.Hardware.ChipFamily,
			"chip_tier":                      p.Hardware.ChipTier,
			"machine_model":                  p.Hardware.MachineModel,
			"memory_gb":                      p.Hardware.MemoryGB,
			"gpu_cores":                      p.Hardware.GPUCores,
			"cpu_cores":                      p.Hardware.CPUCores,
			"memory_bandwidth_gbs":           p.Hardware.MemoryBandwidthGBs,
			"status":                         status,
			"trust_level":                    string(p.TrustLevel),
			"decode_tps":                     p.DecodeTPS,
			"requests_served":                p.Stats.RequestsServed,
			"tokens_generated":               p.Stats.TokensGenerated,
			"cancellations_received":         p.Stats.CancellationsReceived,
			"cancellations_before_output":    p.Stats.CancellationsBeforeOutput,
			"cancellations_partial_complete": p.Stats.CancellationsPartialComplete,
			"generation_errors_after_output": p.Stats.GenerationErrorsAfterOutput,
			"chunk_encryption_errors":        p.Stats.ChunkEncryptionErrors,
			"stream_closed_without_terminal": p.Stats.StreamClosedWithoutTerminal,
			"cancel_during_model_load":       p.Stats.CancelDuringModelLoad,
			"usage_gaps":                     p.Stats.UsageGaps,
			"models":                         provModels,
			"current_model":                  modelSnapshot.CurrentModel,
			"attested":                       p.Attested,
			"mda_verified":                   p.MDAVerified,
			"acme_verified":                  false, // deprecated: ACME leg removed; key kept for older consumers
			"runtime_verified":               p.RuntimeVerified,
			"certificate_available":          len(p.MDACertChain) > 0,
			"last_challenge_verified":        lastChallengeVerified,
			"failed_challenges":              p.FailedChallenges,
		}
		providers = append(providers, prov)

		for _, id := range provModels {
			modelMap[id]++
		}
	})

	var models []map[string]any
	for id, count := range modelMap {
		models = append(models, map[string]any{
			"id":        id,
			"providers": count,
		})
	}
	if models == nil {
		models = []map[string]any{}
	}
	if providers == nil {
		providers = []map[string]any{}
	}

	// Read historical totals via SQL aggregation (no per-row wire transfer).
	totals, totalsErr := s.store().UsageTotals()
	if totals.Requests > totalRequests {
		totalRequests = totals.Requests
	}
	totalPromptTokens := totals.PromptTokens
	totalCompletionTokens := totals.CompletionTokens
	if totalTokensGen > totalCompletionTokens {
		totalCompletionTokens = totalTokensGen
	}
	totalTokens := totalPromptTokens + totalCompletionTokens

	var avgTokens float64
	if totalRequests > 0 {
		avgTokens = float64(totalTokens) / float64(totalRequests)
	}

	// Build time series via SQL bucket aggregation (last 30 minutes), plus exact
	// 24-hour totals for the headline deltas. Geography and route analytics use
	// the full 24-hour window advertised by the public UI.
	now := snapshotAt
	timeSeriesCutoff := now.Add(-30 * time.Minute)
	analyticsCutoff := now.Add(-24 * time.Hour)
	buckets, seriesErr := s.store().UsageTimeSeries(timeSeriesCutoff, now, time.Minute)
	last24h, last24hErr := s.store().UsageTotalsSince(analyticsCutoff)

	timeSeries := make([]map[string]any, 0, len(buckets))
	for _, b := range buckets {
		timeSeries = append(timeSeries, map[string]any{
			"timestamp":         b.Minute.UTC().Format(time.RFC3339),
			"requests":          b.Requests,
			"prompt_tokens":     b.PromptTokens,
			"completion_tokens": b.CompletionTokens,
			"total_tokens":      b.PromptTokens + b.CompletionTokens,
		})
	}

	// --- Provider location aggregation ---
	providerLocations, providerRegions, unknownLocationProviders, suppressedCityProviders := s.aggregateProviderLocations()

	// Geography queries run independently of the core stats refresher. Never
	// wait for them here, including on a cold cache or during a geo outage.
	geography := s.cachedStatsGeography()
	if err := errors.Join(totalsErr, seriesErr, last24hErr); err != nil {
		return nil, err
	}

	// --- APNs code-identity coverage (for watching the grace→enforce rollout) ---
	codeAttestedProviders, _ := s.registry().CodeAttestationCoverage()
	codeAttestationEnforced := s.registry().CodeAttestationEnforced()

	// --- Release-policy application-evidence coverage (the shadow→enforce
	// acceptance instrument: enforcement is safe only once holding ≈ connected
	// fleet-wide AND with_evidence ≈ routable for EVERY model, so one model
	// family's uncovered providers cannot hide inside a healthy average) ---
	evidenceProviders, evidenceConnected := s.registry().CountProvidersWithCurrentApplicationEvidence()
	evidenceModels := s.registry().ApplicationEvidenceModelCoverage()
	releasePolicyEnforced := s.registry().ReleasePolicyEnforced()

	// --- Network utilization (demand/capacity across warm-serving + token-budget axes) ---
	util := s.registry().NetworkUtilizationSnapshot()

	resp := map[string]any{
		"snapshot_at":                    snapshotAt.UTC().Format(time.RFC3339Nano),
		"total_requests":                 totalRequests,
		"total_prompt_tokens":            totalPromptTokens,
		"total_completion_tokens":        totalCompletionTokens,
		"total_tokens":                   totalTokens,
		"last_24h_requests":              last24h.Requests,
		"last_24h_prompt_tokens":         last24h.PromptTokens,
		"last_24h_completion_tokens":     last24h.CompletionTokens,
		"last_24h_total_tokens":          last24h.PromptTokens + last24h.CompletionTokens,
		"location_window_hours":          24,
		"avg_tokens_per_request":         avgTokens,
		"active_providers":               len(providers),
		"active_power_watts":             activePowerWatts,
		"code_attested_providers":        codeAttestedProviders,
		"code_attestation_enforced":      codeAttestationEnforced,
		"application_evidence_providers": evidenceProviders,
		"application_evidence_connected": evidenceConnected,
		"release_policy_enforced":        releasePolicyEnforced,
		"application_evidence_models":    evidenceModels,
		"total_gpu_cores":                totalGPUCores,
		"total_cpu_cores":                totalCPUCores,
		"total_memory_gb":                totalMemoryGB,
		"total_bandwidth_gbs":            totalBandwidthGB,
		"network_capacity_tps":           util.CapacityTPS,
		"network_utilization":            util.Public(),
		"providers":                      providers,
		"models":                         models,
		"time_series":                    timeSeries,

		// Location analytics (privacy-floored).
		"provider_locations":                 providerLocations,
		"provider_regions":                   providerRegions,
		"unknown_location_providers":         unknownLocationProviders,
		"suppressed_city_location_providers": suppressedCityProviders,
		"location_privacy_min_providers":     minProvidersPerCityBucket,
	}
	geography.addTo(resp)
	return json.Marshal(resp)
}
