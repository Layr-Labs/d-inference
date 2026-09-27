package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"testing"
)

func TestPrefixCacheTelemetryFlowsThroughAcceptedHeartbeat(t *testing.T) {
	srv, _ := testServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)
	p := newMLXTelemetryProvider(t, srv.registry, "cache-metrics-private-provider", "M3", "0.8.20")
	var capacitySeq uint64
	flush := func() []string {
		_ = dd.Statsd.Flush()
		return findMetrics(collector.drain(), "provider.prefix_cache.")
	}
	apply := func(sample *protocol.PrefixCacheTelemetry, maintenance uint64) []string {
		capacitySeq++
		capacity := &protocol.BackendCapacity{CapacitySeq: capacitySeq,
			Slots:                  []protocol.BackendSlotCapacity{{Model: "test-model", State: "idle", PrefixCache: sample}},
			PrefixCacheMaintenance: &protocol.PrefixCacheMaintenanceTelemetry{TTLExpiredTotal: maintenance}}
		if !srv.applyProviderHeartbeat(p.ID, p, &protocol.HeartbeatMessage{BackendCapacity: capacity}) {
			t.Fatal("fresh heartbeat rejected")
		}
		return flush()
	}
	sample := func(generation, seq, age, bytes uint64) *protocol.PrefixCacheTelemetry {
		return &protocol.PrefixCacheTelemetry{Kind: "complete_checkpoint", Generation: generation, SampleSeq: seq,
			SampleAgeMS: age, Entries: 2, DiskBytes: 4096, WrittenBytesTotal: bytes,
			IO: &protocol.PrefixCacheIOTelemetry{ReadBytesTotal: bytes * 2, StageUSTotal: bytes * 3}}
	}
	expect := func(packets []string, wants ...string) {
		t.Helper()
		for _, want := range wants {
			if !hasMetric(packets, want) {
				t.Fatalf("missing %s in %v", want, packets)
			}
		}
	}
	noCounts := func(packets []string) {
		t.Helper()
		if hasMetric(packets, "|c") {
			t.Fatalf("unexpected counter delta %v", packets)
		}
	}
	first := apply(sample(1, 1, 0, 10), 1)
	expect(first, "prefix_cache.entries:2|h", "prefix_cache.disk_bytes:4096|h")
	noCounts(first)
	assertBoundedTags(t, first)
	for _, packet := range first {
		if containsTag(packet, "model:test-model") || containsTag(packet, "generation:1") {
			t.Fatalf("unbounded tags: %v", first)
		}
	}
	second := apply(sample(1, 2, 0, 20), 3)
	expect(second, "prefix_cache.written_bytes:10|c", "prefix_cache.read_bytes:20|c",
		"prefix_cache.stage_duration_us:30|c", "prefix_cache.sweep.ttl_expired:2|c")
	if hasMetric(second, "stage_duration_us:30|h") {
		t.Fatal("cumulative duration was emitted as latency sample")
	}
	repeated := apply(sample(1, 2, 90000, 999), 3)
	noCounts(repeated)
	if hasMetric(repeated, "prefix_cache.entries:") {
		t.Fatalf("repeated sample was sampled again: %v", repeated)
	}
	expect(repeated, "prefix_cache.sample_age_ms:90000|h")
	// Regressed low-rate sample inside a newer heartbeat cannot roll back its
	// baseline. A later sequence sees only the change since accepted sample 2.
	noCounts(apply(sample(1, 1, 0, 0), 3))
	expect(apply(sample(1, 3, 0, 30), 3), "prefix_cache.written_bytes:10|c")
	stale := apply(sample(1, 4, capacitySampleFreshMS+1, 40), 3)
	expect(stale, "prefix_cache.sample_fresh:0|h")
	if hasMetric(stale, "prefix_cache.entries:") {
		t.Fatalf("stale sample emitted a current gauge: %v", stale)
	}
	noCounts(apply(sample(2, 1, 0, 1000), 3)) // reload seeds baseline
	noCounts(apply(sample(2, 2, 0, 1), 3))    // cumulative reset contributes no negative count
	noCounts(apply(nil, 3))                   // missing instrumentation clears baseline
	noCounts(apply(sample(2, 3, 0, 100), 3))
	// The existing capacity-sequence gate is also the metric emission gate.
	if srv.applyProviderHeartbeat(p.ID, p, &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{CapacitySeq: capacitySeq}}) {
		t.Fatal("stale heartbeat accepted")
	}
	if packets := flush(); len(packets) != 0 {
		t.Fatalf("stale heartbeat emitted %v", packets)
	}
	// Unknown models and injected kinds never reach metric tags.
	bad := sample(2, 4, 0, 100)
	bad.Kind = "private-prompt-fragment"
	if packets := apply(bad, 3); len(packets) != 0 {
		t.Fatalf("invalid kind emitted: %v", packets)
	}
}
