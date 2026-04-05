package api

import (
	"net/http"
	"sort"
	"time"

	"github.com/eigeninference/coordinator/internal/registry"
)

// handleStats returns aggregate platform statistics for the frontend dashboard.
func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
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

	// Read historical stats from the persistent store (Postgres).
	// The registry only has stats since last restart; the store has everything.
	var storeRequests int64
	var storePromptTokens int64
	var storeCompletionTokens int64
	for _, rec := range s.store.UsageRecords() {
		storeRequests++
		storePromptTokens += int64(rec.PromptTokens)
		storeCompletionTokens += int64(rec.CompletionTokens)
	}

	// Use the larger of store vs registry (store has history, registry has current session)
	if storeRequests > totalRequests {
		totalRequests = storeRequests
	}
	totalPromptTokens := storePromptTokens
	totalCompletionTokens := storeCompletionTokens
	if totalTokensGen > totalCompletionTokens {
		totalCompletionTokens = totalTokensGen
	}
	totalTokens := totalPromptTokens + totalCompletionTokens

	var avgTokens float64
	if totalRequests > 0 {
		avgTokens = float64(totalTokens) / float64(totalRequests)
	}

	// Build time series from usage records (last 30 minutes, 1-minute buckets).
	now := time.Now()
	cutoff := now.Add(-30 * time.Minute)

	type tsBucket struct {
		Requests         int64
		PromptTokens     int64
		CompletionTokens int64
	}
	buckets := make(map[int64]*tsBucket)

	for _, rec := range s.store.UsageRecords() {
		if rec.Timestamp.Before(cutoff) {
			continue
		}
		minuteKey := rec.Timestamp.Truncate(time.Minute).Unix()
		b, ok := buckets[minuteKey]
		if !ok {
			b = &tsBucket{}
			buckets[minuteKey] = b
		}
		b.Requests++
		b.PromptTokens += int64(rec.PromptTokens)
		b.CompletionTokens += int64(rec.CompletionTokens)
	}

	// Sort bucket keys and build the output slice.
	keys := make([]int64, 0, len(buckets))
	for k := range buckets {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })

	timeSeries := make([]map[string]any, 0, len(keys))
	for _, k := range keys {
		b := buckets[k]
		timeSeries = append(timeSeries, map[string]any{
			"timestamp":         time.Unix(k, 0).UTC().Format(time.RFC3339),
			"requests":          b.Requests,
			"prompt_tokens":     b.PromptTokens,
			"completion_tokens": b.CompletionTokens,
			"total_tokens":      b.PromptTokens + b.CompletionTokens,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{
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
	})
}
