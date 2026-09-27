package api

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// recordMLXCacheTelemetry turns the provider heartbeat's allocator snapshot
// into Datadog metrics. Heartbeats are the durable operational path for
// provider diagnostics; unlike the retired free-form telemetry client, they
// carry no prompt or response data and continue flowing during normal serving.
//
// Cardinality: tags are bounded — chip_family and provider_version — never a
// provider id. The previous per-provider gauges were tagged by the connection
// UUID, so every reconnect minted a fresh series (~9 gauges × fleet, churning).
// Point-in-time values are emitted as histograms with DogStatsD (agent-side
// avg/max/p95/count across the fleet per tag set), or as latest-value gauges
// per bounded tag set when the HTTPS series API is configured. HTTP gauges
// preserve visibility without claiming fleet percentiles. Reclaimer counters
// are converted to per-heartbeat deltas against prev (the capacity snapshot
// taken before this heartbeat was applied) and emitted as counts, so a
// fleet-wide reclaim rate survives aggregation. prev is nil on a session's
// first observation: no baseline, no deltas. A counter that went backwards
// (provider-side reset) contributes nothing for that heartbeat.
func (s *Server) recordMLXCacheTelemetry(provider *registry.Provider, prev, capacity *protocol.BackendCapacity) {
	if s.dd == nil || capacity == nil {
		return
	}
	tags := mlxTelemetryTags(provider)
	s.dd.HistogramOrGauge("provider.mlx_memory.active_gb", capacity.GPUMemoryActiveGB, tags)
	s.dd.HistogramOrGauge("provider.mlx_memory.peak_gb", capacity.GPUMemoryPeakGB, tags)
	s.dd.HistogramOrGauge("provider.mlx_memory.cache_gb", capacity.GPUMemoryCacheGB, tags)

	reclaimer := capacity.MLXCacheReclaimer
	if reclaimer == nil {
		return
	}
	s.dd.HistogramOrGauge("provider.mlx_cache.limit_bytes", float64(reclaimer.CacheLimitBytes), tags)

	if prev == nil || prev.MLXCacheReclaimer == nil {
		return
	}
	last := prev.MLXCacheReclaimer
	s.ddCountDelta("provider.mlx_cache.sweep_signals", last.SweepSignals, reclaimer.SweepSignals, tags)
	reclaims := s.ddCountDelta("provider.mlx_cache.reclaims", last.Reclaims, reclaimer.Reclaims, tags)
	s.ddCountDelta("provider.mlx_cache.reclaimed_bytes", last.ReclaimedBytes, reclaimer.ReclaimedBytes, tags)
	if reclaims > 0 {
		// The last_* fields describe the most recent reclaim; sample them
		// only when a reclaim happened since the previous heartbeat so the
		// distribution is of reclaims, not of heartbeats.
		s.dd.HistogramOrGauge("provider.mlx_cache.last_reclaimed_bytes", float64(reclaimer.LastReclaimedBytes), tags)
		s.dd.HistogramOrGauge("provider.mlx_cache.last_reclaim_duration_ms", float64(reclaimer.LastReclaimDurationMS), tags)
	}
}

// ddCountDelta emits cur-prev for a provider-side cumulative counter and
// returns the delta. Nothing is emitted for a zero or negative delta.
func (s *Server) ddCountDelta(name string, prev, cur uint64, tags []string) int64 {
	delta := counterDelta(prev, cur)
	if delta > 0 {
		s.ddCount(name, delta, tags)
	}
	return delta
}

// counterDelta is cur-prev clamped to [0, MaxInt64]; a counter that went
// backwards (provider restart or reset) yields 0.
func counterDelta(prev, cur uint64) int64 {
	if cur <= prev {
		return 0
	}
	if d := cur - prev; d <= math.MaxInt64 {
		return int64(d)
	}
	return math.MaxInt64
}

// mlxTelemetryTags builds the bounded tag set for the MLX telemetry: the chip
// family reported at registration and the provider version, both read under
// the provider's lock and fenced to tag-safe values (provider-controlled
// strings must never mint cardinality).
func mlxTelemetryTags(provider *registry.Provider) []string {
	return []string{
		"chip_family:" + sanitizeChipFamilyTag(providerChipFamily(provider)),
		"provider_version:" + providerVersionTag(provider),
	}
}
