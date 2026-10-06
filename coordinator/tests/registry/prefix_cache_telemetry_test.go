package registry_test

import (
	"log/slog"
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPrefixCacheTelemetryBoundsAndSnapshotOwnership(t *testing.T) {
	reg := production.New(slog.New(slog.DiscardHandler))
	msg := testRegisterMessage()
	p := reg.Register("cache-stats", nil, msg)
	ttl := uint64(math.MaxUint64)
	disarmed := uint64(math.MaxUint64)
	input := &protocol.PrefixCacheTelemetry{Kind: "complete_checkpoint", Generation: 1, SampleSeq: 1,
		Entries: math.MaxUint64, DiskBytes: math.MaxUint64, WrittenBytesTotal: math.MaxUint64, TTLExpiredTotal: &ttl,
		RecurrentCaptureDisarmedPackedTotal: &disarmed,
		IO:                                  &protocol.PrefixCacheIOTelemetry{ReadBytesTotal: math.MaxUint64, StagingPeakBytes: math.MaxUint64}}
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
	if stats.DiskBytes != capacityvalue.MaxCapacitySampleGaugeBytes || stats.WrittenBytesTotal != capacityvalue.MaxCapacitySampleValue || *stats.TTLExpiredTotal != capacityvalue.MaxCapacitySampleValue || stats.IO.StagingPeakBytes != capacityvalue.MaxCapacitySampleGaugeBytes {
		t.Fatalf("bounds: %+v %+v", stats, stats.IO)
	}
	if stats.RecurrentCaptureDisarmedPackedTotal == nil || *stats.RecurrentCaptureDisarmedPackedTotal != capacityvalue.MaxCapacitySampleValue {
		t.Fatalf("recurrent disarm counter bounds: %+v", stats.RecurrentCaptureDisarmedPackedTotal)
	}
	if input.DiskBytes != math.MaxUint64 || ttl != math.MaxUint64 || disarmed != math.MaxUint64 {
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
		if capacityvalue.ClampPrefixCacheTelemetry(invalid) != nil {
			t.Fatalf("invalid sample accepted: %+v", invalid)
		}
	}
	attentionDisarmed := uint64(3)
	attention := capacityvalue.ClampPrefixCacheTelemetry(&protocol.PrefixCacheTelemetry{Kind: "attention_blocks", Generation: 1, SampleSeq: 1, IO: &protocol.PrefixCacheIOTelemetry{ReadBytesTotal: 100}, RecurrentCaptureDisarmedPackedTotal: &attentionDisarmed})
	if attention.IO != nil || attention.RecurrentCaptureDisarmedPackedTotal != nil {
		t.Fatal("unproduced attention read metrics were accepted")
	}
	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{})
	if p.BackendCapacitySnapshot() != nil {
		t.Fatal("nil heartbeat retained telemetry")
	}
}
