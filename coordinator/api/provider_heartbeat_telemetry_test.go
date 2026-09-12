package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestRejectedHeartbeatDoesNotEmitAllocatorSamples(t *testing.T) {
	srv, _ := testServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)
	p := newMLXTelemetryProvider(t, srv.registry, "sequence-telemetry", "M3", "0.8.20")
	apply := func(seq uint64) bool {
		capacity := mlxCapacity(5, 2, 4096)
		capacity.CapacitySeq = seq
		return srv.applyProviderHeartbeat(p.ID, p, &protocol.HeartbeatMessage{BackendCapacity: capacity})
	}
	if !apply(2) {
		t.Fatal("first stamped heartbeat was rejected")
	}
	_ = dd.Statsd.Flush()
	if !hasMetric(collector.drain(), "provider.mlx_memory.active_gb") {
		t.Fatal("accepted heartbeat did not emit allocator telemetry")
	}
	for _, seq := range []uint64{2, 1} {
		if apply(seq) {
			t.Errorf("reordered sequence %d was accepted", seq)
		}
	}
	_ = dd.Statsd.Flush()
	if packets := collector.drain(); len(findMetrics(packets, "provider.mlx_")) != 0 {
		t.Fatalf("rejected heartbeats emitted repeated allocator samples: %v", packets)
	}
	if !apply(0) {
		t.Fatal("legacy unsequenced heartbeat was rejected")
	}
	_ = dd.Statsd.Flush()
	if !hasMetric(collector.drain(), "provider.mlx_memory.active_gb") {
		t.Fatal("legacy accepted heartbeat stopped reporting telemetry")
	}
}
