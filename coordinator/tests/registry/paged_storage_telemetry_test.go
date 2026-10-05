package registry_test

import (
	"log/slog"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCapacitySamplesAgeWithoutProducerProgress(t *testing.T) {
	old := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "model",
		PrefixCache:  &protocol.PrefixCacheTelemetry{Kind: "complete_checkpoint", Generation: 1, SampleSeq: 3, Entries: 2},
		PagedStorage: &protocol.PagedStorageTelemetry{Kind: "segmented", Generation: 1, SampleSeq: 3, CommittedBytes: 100}}}}
	current := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "model",
		PrefixCache:  &protocol.PrefixCacheTelemetry{Kind: "complete_checkpoint", Generation: 1, SampleSeq: 3, Entries: 999},
		PagedStorage: &protocol.PagedStorageTelemetry{Kind: "segmented", Generation: 1, SampleSeq: 2, CommittedBytes: 999}}}}
	capacityvalue.ReconcileSamples(old, current, 6*time.Minute)
	s := current.Slots[0]
	if s.PrefixCache.Entries != 2 || s.PagedStorage.CommittedBytes != 100 || s.PrefixCache.SampleAgeMS != 360000 || s.PagedStorage.SampleAgeMS != 360000 {
		t.Fatalf("stopped producer was freshened: %+v %+v", s.PrefixCache, s.PagedStorage)
	}
	s.PagedStorage.Generation = 2
	s.PagedStorage.CommittedBytes = 50
	s.PagedStorage.SampleAgeMS = 0
	current.Slots[0] = s
	capacityvalue.ReconcileSamples(old, current, time.Minute)
	if current.Slots[0].PagedStorage.CommittedBytes != 50 || current.Slots[0].PagedStorage.SampleAgeMS != 0 {
		t.Fatal("new generation inherited old data")
	}
	current.Slots[0].PagedStorage = nil
	capacityvalue.ReconcileSamples(old, current, time.Minute)
	if current.Slots[0].PagedStorage != nil {
		t.Fatal("absent sample resurrected")
	}
}

func TestCapacitySamplesAgeIncludesRejectedHeartbeats(t *testing.T) {
	oldCapture := time.Now().Add(-6 * time.Minute)
	now := oldCapture
	history := &capacityvalue.SampleHistory{}
	reg := production.NewWithDependencies(slog.New(slog.DiscardHandler), production.Dependencies{
		CapacitySamples: func(string) *capacityvalue.SampleHistory { return history },
		HeartbeatNow:    func() time.Time { return now },
	})
	registration := testRegisterMessage()
	p := reg.Register("paged-age", nil, registration)
	if *history != (capacityvalue.SampleHistory{}) {
		t.Fatal("new connection inherited a sample clock")
	}
	heartbeat := func(capacitySeq, generation uint64) *protocol.HeartbeatMessage {
		return &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{CapacitySeq: capacitySeq,
			Slots: []protocol.BackendSlotCapacity{{Model: registration.Models[0].ID,
				PrefixCache:  &protocol.PrefixCacheTelemetry{Kind: "complete_checkpoint", Generation: generation, SampleSeq: 1},
				PagedStorage: &protocol.PagedStorageTelemetry{Kind: "segmented", Generation: generation, SampleSeq: 1}}}}}
	}
	if !reg.Heartbeat(p.ID, heartbeat(1, 1)) {
		t.Fatal("first sample rejected")
	}
	// The real accepted heartbeat establishes the old sample and liveness clocks.
	accepted := *history
	now = time.Now()
	for range 3 {
		if reg.Heartbeat(p.ID, heartbeat(1, 1)) {
			t.Fatal("duplicate capacity sequence accepted")
		}
	}
	p.Mu().Lock()
	live := p.LastHeartbeat
	p.Mu().Unlock()
	if !live.After(oldCapture) || *history != accepted {
		t.Fatal("rejected frames changed sample time or failed to prove liveness")
	}
	if !reg.Heartbeat(p.ID, heartbeat(2, 1)) {
		t.Fatal("next capacity rejected")
	}
	slot := p.BackendCapacitySnapshot().Slots[0]
	if slot.PagedStorage.SampleAgeMS < 360000 || slot.PrefixCache.SampleAgeMS < 360000 {
		t.Fatalf("rejected frames freshened stopped producers: paged=%d prefix=%d", slot.PagedStorage.SampleAgeMS, slot.PrefixCache.SampleAgeMS)
	}
	if !reg.Heartbeat(p.ID, heartbeat(3, 2)) || p.BackendCapacitySnapshot().Slots[0].PagedStorage.SampleAgeMS != 0 {
		t.Fatal("reloaded pool inherited stale age")
	}
	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 4}})
	if *history != (capacityvalue.SampleHistory{}) {
		t.Fatal("slot removal retained sample clock")
	}
	reg.Heartbeat(p.ID, heartbeat(5, 2))
	if p.BackendCapacitySnapshot().Slots[0].PagedStorage.SampleAgeMS != 0 {
		t.Fatal("replacement inherited removed sample age")
	}
	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{})
	if *history != (capacityvalue.SampleHistory{}) {
		t.Fatal("nil capacity retained sample clock")
	}
}

func TestPagedStorageTelemetryBoundsAndSnapshotOwnership(t *testing.T) {
	reg := production.New(slog.New(slog.DiscardHandler))
	msg := testRegisterMessage()
	p := reg.Register("paged-stats", nil, msg)
	value := uint64(math.MaxUint64)
	input := &protocol.PagedStorageTelemetry{Kind: "segmented", Generation: 1, SampleSeq: 1,
		CommittedBytes: value, SegmentCount: value, NominalKVBytes: &value, AllocationFailuresTotal: &value,
		AllocatorPaddingBytes: &value, LastAllocationAllowanceBytes: &value}
	hb := &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{
		{Model: msg.Models[0].ID, PagedStorage: input}, {Model: "private-unknown", PagedStorage: input}}}}
	if !reg.Heartbeat(p.ID, hb) {
		t.Fatal("heartbeat rejected")
	}
	snapshot := p.BackendCapacitySnapshot()
	if len(snapshot.Slots) != 1 {
		t.Fatal("unknown model retained")
	}
	s := snapshot.Slots[0].PagedStorage
	if s.CommittedBytes != capacityvalue.MaxCapacitySampleGaugeBytes || *s.NominalKVBytes != capacityvalue.MaxCapacitySampleGaugeBytes || *s.AllocationFailuresTotal != capacityvalue.MaxCapacitySampleValue || s.SegmentCount != 1<<32 {
		t.Fatalf("bounds: %+v", s)
	}
	if *s.AllocatorPaddingBytes != capacityvalue.MaxCapacitySampleGaugeBytes || *s.LastAllocationAllowanceBytes != capacityvalue.MaxCapacitySampleGaugeBytes {
		t.Fatal("new gauges escaped bounds")
	}
	*s.AllocatorPaddingBytes, *s.LastAllocationAllowanceBytes = 3, 4
	*s.NominalKVBytes, *s.AllocationFailuresTotal = 1, 2
	fresh := p.BackendCapacitySnapshot().Slots[0].PagedStorage
	if *fresh.NominalKVBytes == 1 || *fresh.AllocationFailuresTotal == 2 || *fresh.AllocatorPaddingBytes == 3 || *fresh.LastAllocationAllowanceBytes == 4 {
		t.Fatal("snapshot aliases registry")
	}
	if value != math.MaxUint64 {
		t.Fatal("registry mutated decoder input")
	}
	for _, bad := range []*protocol.PagedStorageTelemetry{{Kind: "private-fragment", Generation: 1, SampleSeq: 1}, {Kind: "segmented", Generation: 0, SampleSeq: 1}, {Kind: "segmented", Generation: 1}} {
		if capacityvalue.ClampPagedStorageTelemetry(bad) != nil {
			t.Fatal("invalid sample retained")
		}
	}
	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{})
	if p.BackendCapacitySnapshot() != nil {
		t.Fatal("missing capacity retained samples")
	}
	reg.Disconnect(p.ID)
	reconnected := reg.Register("paged-stats-new", nil, msg)
	if c := reconnected.BackendCapacitySnapshot(); c != nil {
		for _, slot := range c.Slots {
			if slot.PagedStorage != nil {
				t.Fatal("reconnect retained old generation")
			}
		}
	}
}
