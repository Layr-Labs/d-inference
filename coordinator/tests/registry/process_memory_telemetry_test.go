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

func TestProcessMemoryTelemetryAcceptanceIsolationAndBounds(t *testing.T) {
	history := &capacityvalue.SampleHistory{}
	reg := production.NewWithDependencies(slog.New(slog.DiscardHandler), production.Dependencies{
		CapacitySamples: func(string) *capacityvalue.SampleHistory { return history },
	})
	p := reg.Register("memory-test", nil, testRegisterMessage())
	original := memoryObservation(1, 1)
	hb := &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1,
		Telemetry: &protocol.CapacityTelemetry{ProcessMemory: original}}}
	if !reg.Heartbeat(p.ID, hb) {
		t.Fatal("heartbeat rejected")
	}
	snapshot := p.BackendCapacitySnapshot().Telemetry.ProcessMemory
	snapshot.ChargedBytes = 0
	*snapshot.SystemAvailableBytes = 0
	if original.ChargedBytes != 250 || p.BackendCapacitySnapshot().Telemetry.ProcessMemory.ChargedBytes != 250 || *original.SystemAvailableBytes != 700 {
		t.Fatal("heartbeat/snapshot alias")
	}
	if *history == (capacityvalue.SampleHistory{}) {
		t.Fatal("process-only sample has no capture clock")
	}
	cases := []func(*protocol.ProcessMemoryTelemetry){
		func(m *protocol.ProcessMemoryTelemetry) { m.Generation = 0 },
		func(m *protocol.ProcessMemoryTelemetry) { m.SampleSeq = 0 },
		func(m *protocol.ProcessMemoryTelemetry) { m.MaterializedBytes = 251 },
		func(m *protocol.ProcessMemoryTelemetry) { m.UnmaterializedBytes = 51 },
		func(m *protocol.ProcessMemoryTelemetry) { m.ClosingOwnerCount = 4 },
		func(m *protocol.ProcessMemoryTelemetry) { m.ChargedBytes = math.MaxUint64 },
		func(m *protocol.ProcessMemoryTelemetry) { m.CommitmentDebtBytes = 1 },
		func(m *protocol.ProcessMemoryTelemetry) { m.RemainingBytes = 1000 },
		func(m *protocol.ProcessMemoryTelemetry) { m.RemainingBytes = 0; m.CommitmentDebtBytes = 100 },
		func(m *protocol.ProcessMemoryTelemetry) { *m.SystemAvailableBytes = math.MaxUint64 },
	}
	for i, change := range cases {
		bad := memoryObservation(1, 2)
		change(bad)
		if capacityvalue.ValidProcessMemoryTelemetry(bad) != nil {
			t.Fatalf("invalid case %d retained", i)
		}
	}
	if !reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 2}}) {
		t.Fatal("empty heartbeat rejected")
	}
	if p.BackendCapacitySnapshot().Telemetry != nil {
		t.Fatal("absent observation resurrected")
	}
}

func TestProcessMemoryTelemetryAgesWithoutSlotsOrProducerProgress(t *testing.T) {
	capacity := func(m *protocol.ProcessMemoryTelemetry) *protocol.BackendCapacity {
		return &protocol.BackendCapacity{Telemetry: &protocol.CapacityTelemetry{ProcessMemory: m}}
	}
	previous, current := capacity(memoryObservation(1, 3)), capacity(memoryObservation(1, 3))
	current.Telemetry.ProcessMemory.ActiveBytes = 900
	capacityvalue.ReconcileSamples(previous, current, 6*time.Minute)
	m := current.Telemetry.ProcessMemory
	if m.SampleAgeMS != 360000 || m.ActiveBytes != 500 {
		t.Fatalf("repeat freshened process sample: %+v", m)
	}
	current = capacity(memoryObservation(1, 2))
	capacityvalue.ReconcileSamples(previous, current, time.Minute)
	if current.Telemetry.ProcessMemory.SampleSeq != 3 || current.Telemetry.ProcessMemory.SampleAgeMS != 60000 {
		t.Fatal("regressed sequence accepted")
	}
	current = capacity(memoryObservation(2, 1))
	capacityvalue.ReconcileSamples(previous, current, time.Minute)
	if current.Telemetry.ProcessMemory.Generation != 2 || current.Telemetry.ProcessMemory.SampleAgeMS != 0 {
		t.Fatal("new process kept old sample")
	}
	current = capacity(nil)
	capacityvalue.ReconcileSamples(previous, current, time.Minute)
	if current.Telemetry.ProcessMemory != nil {
		t.Fatal("absent telemetry resurrected")
	}
}

func memoryObservation(generation, seq uint64) *protocol.ProcessMemoryTelemetry {
	available := uint64(700)
	return &protocol.ProcessMemoryTelemetry{Generation: generation, SampleSeq: seq,
		PolicyEpoch: 1, CapBytes: 1000, ActiveBytes: 500, CacheBytes: 100,
		ActivationReserveBytes: 100, ChargedBytes: 250, MaterializedBytes: 200,
		UnmaterializedBytes: 50, RemainingBytes: 250, OwnerCount: 3, ClosingOwnerCount: 1,
		SystemAvailableBytes: &available}
}

func TestProcessMemoryTelemetryHeadroomIdentity(t *testing.T) {
	cases := []struct {
		name                   string
		active, cache, reserve uint64
		system                 *uint64
		remaining, debt        uint64
	}{
		{"cap limited", 500, 100, 100, memoryBytes(700), 250, 0},
		{"OS limited", 500, 100, 100, memoryBytes(200), 50, 0},
		{"OS unknown", 500, 100, 100, nil, 250, 0},
		{"OS unavailable", 500, 100, 100, memoryBytes(0), 0, 50},
		{"reserve exceeds headroom", 500, 100, 500, nil, 0, 50},
		{"allocator exceeds cap", 900, 200, 0, nil, 0, 50},
		{"partial promise debt", 950, 0, 25, nil, 0, 25},
		{"exactly committed", 950, 0, 0, nil, 0, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := memoryObservation(1, 1)
			m.ActiveBytes, m.CacheBytes, m.ActivationReserveBytes = tc.active, tc.cache, tc.reserve
			m.SystemAvailableBytes = tc.system
			m.RemainingBytes, m.CommitmentDebtBytes = tc.remaining, tc.debt
			if capacityvalue.ValidProcessMemoryTelemetry(m) == nil {
				t.Fatal("consistent sample rejected")
			}
			m.RemainingBytes++
			if capacityvalue.ValidProcessMemoryTelemetry(m) != nil {
				t.Fatal("invented headroom retained")
			}
			m.RemainingBytes--
			m.CommitmentDebtBytes++
			if capacityvalue.ValidProcessMemoryTelemetry(m) != nil {
				t.Fatal("invented debt retained")
			}
		})
	}
}

func memoryBytes(n uint64) *uint64 { return &n }
