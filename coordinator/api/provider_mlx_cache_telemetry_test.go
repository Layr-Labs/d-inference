package api

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestRecordMLXCacheTelemetryEmitsHeartbeatGauges(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()

	s := &Server{}
	s.SetDatadog(ddClient)
	s.recordMLXCacheTelemetry("provider-1", &protocol.BackendCapacity{
		GPUMemoryActiveGB: 21,
		GPUMemoryPeakGB:   31,
		GPUMemoryCacheGB:  6,
		MLXCacheReclaimer: &protocol.MLXCacheReclaimerTelemetry{
			CacheLimitBytes:       8 << 30,
			SweepSignals:          12,
			Reclaims:              4,
			ReclaimedBytes:        24 << 30,
			LastReclaimedBytes:    6 << 30,
			LastReclaimDurationMS: 17,
		},
	})
	_ = ddClient.Statsd.Flush()
	payload := strings.Join(collector.drain(), "\n")

	for _, metric := range []string{
		"provider.mlx_memory.active_gb",
		"provider.mlx_memory.peak_gb",
		"provider.mlx_memory.cache_gb",
		"provider.mlx_cache.limit_bytes",
		"provider.mlx_cache.sweep_signals_total",
		"provider.mlx_cache.reclaims_total",
		"provider.mlx_cache.reclaimed_bytes_total",
		"provider.mlx_cache.last_reclaimed_bytes",
		"provider.mlx_cache.last_reclaim_duration_ms",
	} {
		if !strings.Contains(payload, metric) {
			t.Errorf("missing %s in DogStatsD payload: %s", metric, payload)
		}
	}
	if !strings.Contains(payload, "provider_id:provider-1") {
		t.Fatalf("allocator gauges must identify the provider: %s", payload)
	}
}

func TestRecordMLXCacheTelemetryLegacyAndNilSafe(t *testing.T) {
	s := &Server{}
	// No Datadog client and no reclaimer block are both valid during rollout.
	s.recordMLXCacheTelemetry("legacy", nil)
	s.recordMLXCacheTelemetry("legacy", &protocol.BackendCapacity{
		GPUMemoryActiveGB: 1,
		GPUMemoryPeakGB:   2,
		GPUMemoryCacheGB:  0.5,
	})
}
