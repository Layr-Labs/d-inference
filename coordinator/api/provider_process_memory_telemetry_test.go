package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestProcessMemoryTelemetryAcceptedHeartbeatMetrics(t *testing.T) {
	srv, _ := testServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)
	p := newMLXTelemetryProvider(t, srv.registry, "private-memory-owner", "M3", "0.9.0")
	flush := func() []string {
		_ = dd.Statsd.Flush()
		return findMetrics(collector.drain(), "provider.process_memory.")
	}
	var seq uint64
	sample := func(generation, sequence, age uint64) *protocol.ProcessMemoryTelemetry {
		return &protocol.ProcessMemoryTelemetry{Generation: generation, SampleSeq: sequence,
			SampleAgeMS: age, CapBytes: 1000, ActiveBytes: 500, CacheBytes: 100,
			ChargedBytes: 250, MaterializedBytes: 200, UnmaterializedBytes: 50,
			RemainingBytes: 350, OwnerCount: 2, ClosingOwnerCount: 1}
	}
	apply := func(m *protocol.ProcessMemoryTelemetry) []string {
		seq++
		capacity := &protocol.BackendCapacity{CapacitySeq: seq, Telemetry: &protocol.CapacityTelemetry{ProcessMemory: m}}
		if !srv.applyProviderHeartbeat(p.ID, p, &protocol.HeartbeatMessage{BackendCapacity: capacity}) {
			t.Fatal("heartbeat rejected")
		}
		return flush()
	}
	first := apply(sample(1, 1, 0))
	for _, want := range []string{"charged_bytes:250|h", "materialized_bytes:200|h", "unmaterialized_bytes:50|h", "closing_owner_count:1|h"} {
		if !hasMetric(first, want) {
			t.Fatalf("missing %s in %v", want, first)
		}
	}
	for _, packet := range first {
		if !containsTag(packet, "chip_family:M3") || !containsTag(packet, "provider_version:0.9.x") || containsTag(packet, "provider_id:private-memory-owner") || containsTag(packet, "generation:1") {
			t.Fatalf("bad label: %s", packet)
		}
	}
	if hasMetric(first, "system_available_bytes:") {
		t.Fatal("unknown OS availability reported zero")
	}
	repeat := apply(sample(1, 1, 90000))
	if hasMetric(repeat, "charged_bytes:") || !hasMetric(repeat, "sample_age_ms:90000|h") {
		t.Fatalf("repeated sample: %v", repeat)
	}
	stale := apply(sample(1, 2, capacitySampleFreshMS+1))
	if hasMetric(stale, "charged_bytes:") || !hasMetric(stale, "sample_fresh:0|h") {
		t.Fatalf("stale sample: %v", stale)
	}
	if packets := apply(sample(2, 1, 0)); !hasMetric(packets, "charged_bytes:250|h") {
		t.Fatalf("new generation: %v", packets)
	}
	if packets := apply(nil); len(packets) != 0 {
		t.Fatalf("absent sample: %v", packets)
	}
	bad := sample(2, 2, 0)
	bad.MaterializedBytes = 300
	if packets := apply(bad); len(packets) != 0 {
		t.Fatalf("invalid sample: %v", packets)
	}
	if srv.applyProviderHeartbeat(p.ID, p, &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{CapacitySeq: seq}}) {
		t.Fatal("stale capacity accepted")
	}
	if packets := flush(); len(packets) != 0 {
		t.Fatalf("rejected frame emitted metrics: %v", packets)
	}
}
