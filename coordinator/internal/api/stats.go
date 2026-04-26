package api

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/eigeninference/coordinator/internal/registry"
)

// handleStats returns aggregate platform statistics for the frontend dashboard.
//
// Cached for 60s — the underlying SQL aggregation runs in <5ms but this
// endpoint is hit by every dashboard refresh and the homepage live ticker.
func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	const cacheKey = "stats:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, http.StatusOK, cached)
		return
	}
	var (
		totalRequests    int64
		totalTokensGen   int64
		totalGPUCores    int
		totalCPUCores    int
		totalMemoryGB    int
		totalBandwidthGB float64
		providers        []map[string]any
		modelMap         = map[string]int{} // model ID → provider count
	)

	s.registry.ForEachProvider(func(p *registry.Provider) {
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

		// Collect available model IDs for this provider
		provModels := make([]string, 0, len(p.Models))
		for _, m := range p.Models {
			provModels = append(provModels, m.ID)
		}

		prov := map[string]any{
			"id":                   p.ID,
			"chip":                 p.Hardware.ChipName,
			"chip_family":          p.Hardware.ChipFamily,
			"chip_tier":            p.Hardware.ChipTier,
			"machine_model":        p.Hardware.MachineModel,
			"memory_gb":            p.Hardware.MemoryGB,
			"gpu_cores":            p.Hardware.GPUCores,
			"cpu_cores":            p.Hardware.CPUCores,
			"memory_bandwidth_gbs": p.Hardware.MemoryBandwidthGBs,
			"status":               status,
			"trust_level":          string(p.TrustLevel),
			"decode_tps":           p.DecodeTPS,
			"requests_served":      p.Stats.RequestsServed,
			"tokens_generated":     p.Stats.TokensGenerated,
			"models":               provModels,
			"current_model":        p.CurrentModel,
		}
		providers = append(providers, prov)

		for _, m := range p.Models {
			modelMap[m.ID]++
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
	totals := s.store.UsageTotals()
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

	// Build time series via SQL bucket aggregation (last 30 minutes).
	now := time.Now()
	cutoff := now.Add(-30 * time.Minute)
	buckets := s.store.UsageTimeSeries(cutoff)

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

	resp := map[string]any{
		"total_requests":          totalRequests,
		"total_prompt_tokens":     totalPromptTokens,
		"total_completion_tokens": totalCompletionTokens,
		"total_tokens":            totalTokens,
		"avg_tokens_per_request":  avgTokens,
		"active_providers":        len(providers),
		"total_gpu_cores":         totalGPUCores,
		"total_cpu_cores":         totalCPUCores,
		"total_memory_gb":         totalMemoryGB,
		"total_bandwidth_gbs":     totalBandwidthGB,
		"network_capacity_tps":    0, // would need benchmark data
		"providers":               providers,
		"models":                  models,
		"time_series":             timeSeries,
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode stats"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, http.StatusOK, body)
}
