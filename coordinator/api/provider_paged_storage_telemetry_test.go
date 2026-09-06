package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPagedStorageTelemetryFlowsThroughAcceptedHeartbeat(t *testing.T) {
	srv, _ := testServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)
	p := newMLXTelemetryProvider(t, srv.registry, "paged-private-provider", "M3", "0.9.0")
	var capacitySeq uint64
	flush := func() []string {
		_ = dd.Statsd.Flush()
		return findMetrics(collector.drain(), "provider.paged_storage.")
	}
	apply := func(sample *protocol.PagedStorageTelemetry) []string {
		capacitySeq++
		capacity := &protocol.BackendCapacity{CapacitySeq: capacitySeq, Slots: []protocol.BackendSlotCapacity{{Model: "test-model", State: "idle", PagedStorage: sample}}}
		if !srv.applyProviderHeartbeat(p.ID, p, &protocol.HeartbeatMessage{BackendCapacity: capacity}) {
			t.Fatal("fresh heartbeat rejected")
		}
		return flush()
	}
	sample := func(generation, seq, age, failures uint64) *protocol.PagedStorageTelemetry {
		nominal, overhead := uint64(800), uint64(100)
		padding, allowance := uint64(50), uint64(77)
		return &protocol.PagedStorageTelemetry{Kind: "segmented", Generation: generation, SampleSeq: seq, SampleAgeMS: age,
			GrantBytes: 1000, CommittedBytes: 900, ReservedPageBytes: 700, LivePageBytes: 400, PoisonBytes: 100, SlackBytes: 50,
			AllocatorPaddingBytes: &padding, LastAllocationAllowanceBytes: &allowance,
			SegmentCount: 2, AddressPages: 32, NominalKVBytes: &nominal, PhysicalFloorOverheadBytes: &overhead,
			AllocationFailuresTotal: &failures, AdmissionRefusalsTotal: &failures, GrantRefusalsTotal: &failures, GrantEpochRetriesTotal: &failures}
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
			t.Fatalf("unexpected delta: %v", packets)
		}
	}
	first := apply(sample(1, 1, 0, 10))
	expect(first, "paged_storage.committed_bytes:900|h", "paged_storage.nominal_kv_bytes:800|h", "paged_storage.physical_floor_overhead_bytes:100|h")
	expect(first, "paged_storage.allocator_padding_bytes:50|h", "paged_storage.last_allocation_allowance_bytes:77|h")
	noCounts(first)
	for _, packet := range first {
		if !containsTag(packet, "chip_family:M3") || !containsTag(packet, "provider_version:0.9.x") {
			t.Fatalf("bounded fleet labels missing: %s", packet)
		}
		if containsTag(packet, "model:test-model") || containsTag(packet, "generation:1") {
			t.Fatal("unbounded label")
		}
	}
	second := apply(sample(1, 2, 0, 12))
	expect(second, "paged_storage.allocation_failures:2|c", "paged_storage.admission_refusals:2|c", "paged_storage.grant_refusals:2|c", "paged_storage.grant_epoch_retries:2|c")
	repeat := apply(sample(1, 2, 90000, 99))
	noCounts(repeat)
	expect(repeat, "paged_storage.sample_age_ms:90000|h")
	if hasMetric(repeat, "paged_storage.committed_bytes:") || hasMetric(repeat, "paged_storage.allocator_padding_bytes:") || hasMetric(repeat, "paged_storage.last_allocation_allowance_bytes:") {
		t.Fatal("unchanged sample emitted current ownership")
	}
	noCounts(apply(sample(1, 1, 0, 0)))
	expect(apply(sample(1, 3, 0, 13)), "paged_storage.allocation_failures:1|c")
	stale := apply(sample(1, 4, capacitySampleFreshMS+1, 20))
	expect(stale, "paged_storage.sample_fresh:0|h")
	if hasMetric(stale, "paged_storage.committed_bytes:") || hasMetric(stale, "paged_storage.allocator_padding_bytes:") || hasMetric(stale, "paged_storage.last_allocation_allowance_bytes:") {
		t.Fatal("stale ownership sampled as current")
	}
	noCounts(apply(sample(2, 1, 0, 100)))
	noCounts(apply(sample(2, 2, 0, 1)))
	noCounts(apply(nil))
	noCounts(apply(sample(2, 3, 0, 200)))
	legacy := sample(2, 4, 0, 201)
	legacy.AllocatorPaddingBytes, legacy.LastAllocationAllowanceBytes = nil, nil
	legacyPackets := apply(legacy)
	if hasMetric(legacyPackets, "paged_storage.allocator_padding_bytes:") || hasMetric(legacyPackets, "paged_storage.last_allocation_allowance_bytes:") {
		t.Fatal("missing gauges emitted as zero")
	}
	bad := sample(2, 5, 0, 201)
	bad.Kind = "private-fragment"
	if packets := apply(bad); len(packets) != 0 {
		t.Fatalf("invalid kind emitted %v", packets)
	}
	if srv.applyProviderHeartbeat(p.ID, p, &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{CapacitySeq: capacitySeq}}) {
		t.Fatal("stale capacity accepted")
	}
	if packets := flush(); len(packets) != 0 {
		t.Fatalf("rejected heartbeat emitted %v", packets)
	}
}
