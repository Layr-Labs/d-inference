package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"log/slog"
	"math"
	"testing"
)

func TestPrefixCacheTelemetryBoundsAndSnapshotOwnership(t *testing.T) {
	reg := New(slog.New(slog.DiscardHandler))
	msg := testRegisterMessage()
	p := reg.Register("cache-stats", nil, msg)
	ttl := uint64(math.MaxUint64)
	input := &protocol.PrefixCacheTelemetry{Kind: "complete_checkpoint", Generation: 1, SampleSeq: 1,
		Entries: math.MaxUint64, DiskBytes: math.MaxUint64, WrittenBytesTotal: math.MaxUint64, TTLExpiredTotal: &ttl,
		IO: &protocol.PrefixCacheIOTelemetry{ReadBytesTotal: math.MaxUint64, StagingPeakBytes: math.MaxUint64}}
	hb := &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{
		Slots:                  []protocol.BackendSlotCapacity{{Model: msg.Models[0].ID, PrefixCache: input}, {Model: "private-unregistered", PrefixCache: input}},
		PrefixCacheMaintenance: &protocol.PrefixCacheMaintenanceTelemetry{TTLExpiredTotal: math.MaxUint64}}}
	if !reg.Heartbeat(p.ID, hb) {
		t.Fatal("heartbeat rejected")
	}
	snapshot := p.BackendCapacitySnapshot()
	if len(snapshot.Slots) != 1 {
		t.Fatalf("unknown slot retained: %+v", snapshot.Slots)
	}
	stats := snapshot.Slots[0].PrefixCache
	if stats.DiskBytes != maxCapacitySampleGaugeBytes || stats.WrittenBytesTotal != maxCapacitySampleValue || *stats.TTLExpiredTotal != maxCapacitySampleValue || stats.IO.StagingPeakBytes != maxCapacitySampleGaugeBytes {
		t.Fatalf("bounds: %+v %+v", stats, stats.IO)
	}
	if input.DiskBytes != math.MaxUint64 || ttl != math.MaxUint64 {
		t.Fatal("clamp mutated decoder-owned values")
	}
	stats.IO.ReadBytesTotal = 7
	*stats.TTLExpiredTotal = 7
	snapshot.PrefixCacheMaintenance.TTLExpiredTotal = 7
	next := p.BackendCapacitySnapshot()
	if next.Slots[0].PrefixCache.IO.ReadBytesTotal == 7 || *next.Slots[0].PrefixCache.TTLExpiredTotal == 7 || next.PrefixCacheMaintenance.TTLExpiredTotal == 7 {
		t.Fatal("public snapshot aliases registry telemetry")
	}
	for _, invalid := range []*protocol.PrefixCacheTelemetry{{Kind: "secret", Generation: 1, SampleSeq: 1}, {Kind: "attention_blocks", Generation: 0, SampleSeq: 1}, {Kind: "complete_checkpoint", Generation: 1}} {
		if clampPrefixCacheTelemetry(invalid) != nil {
			t.Fatalf("invalid sample accepted: %+v", invalid)
		}
	}
	attention := clampPrefixCacheTelemetry(&protocol.PrefixCacheTelemetry{Kind: "attention_blocks", Generation: 1, SampleSeq: 1, IO: &protocol.PrefixCacheIOTelemetry{ReadBytesTotal: 100}})
	if attention.IO != nil {
		t.Fatal("unproduced attention read metrics were accepted")
	}
	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{})
	if p.BackendCapacitySnapshot() != nil {
		t.Fatal("nil heartbeat retained telemetry")
	}
}
