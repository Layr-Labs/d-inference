package api

import "github.com/eigeninference/d-inference/coordinator/protocol"

// recordMLXCacheTelemetry turns the provider heartbeat's allocator snapshot
// into live Datadog gauges. Heartbeats are the durable operational path for
// provider diagnostics; unlike the retired free-form telemetry client, they
// carry no prompt or response data and continue flowing during normal serving.
//
// Cumulative reclaimer values are gauges rather than coordinator-side counters:
// they reset when the provider process restarts, and Datadog can derive rates
// without the coordinator maintaining per-provider delta state.
func (s *Server) recordMLXCacheTelemetry(providerID string, capacity *protocol.BackendCapacity) {
	if capacity == nil {
		return
	}

	tags := []string{"provider_id:" + providerID}
	s.ddGauge("provider.mlx_memory.active_gb", capacity.GPUMemoryActiveGB, tags)
	s.ddGauge("provider.mlx_memory.peak_gb", capacity.GPUMemoryPeakGB, tags)
	s.ddGauge("provider.mlx_memory.cache_gb", capacity.GPUMemoryCacheGB, tags)

	reclaimer := capacity.MLXCacheReclaimer
	if reclaimer == nil {
		return
	}
	s.ddGauge("provider.mlx_cache.limit_bytes", float64(reclaimer.CacheLimitBytes), tags)
	s.ddGauge("provider.mlx_cache.sweep_signals_total", float64(reclaimer.SweepSignals), tags)
	s.ddGauge("provider.mlx_cache.reclaims_total", float64(reclaimer.Reclaims), tags)
	s.ddGauge("provider.mlx_cache.reclaimed_bytes_total", float64(reclaimer.ReclaimedBytes), tags)
	s.ddGauge("provider.mlx_cache.last_reclaimed_bytes", float64(reclaimer.LastReclaimedBytes), tags)
	s.ddGauge("provider.mlx_cache.last_reclaim_duration_ms", float64(reclaimer.LastReclaimDurationMS), tags)
}
