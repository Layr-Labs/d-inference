package registry

import (
	"log/slog"
	"math"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func i64p(v int64) *int64 { return &v }

// System-profiler heartbeat telemetry: pointer numerics clamp in place, tps
// garbage reads as "not reported", the level enum folds, and absent stays nil.
func TestClampBackendCapacityTelemetry(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	mk := func(tps float64) *protocol.BackendCapacity {
		return &protocol.BackendCapacity{
			Slots: []protocol.BackendSlotCapacity{{Model: "qwen", State: "running", Telemetry: &protocol.SlotTelemetry{
				QueuedPrefillTokens: i64p(-7),
				PrefillTokensTotal:  i64p(maxTelemetryCount + 1),
				KVBytesInUse:        i64p(maxTelemetryBytes + 1),
				EvalInFlightMS:      i64p(maxTelemetryMS + 1),
				StepWallNSTotal:     i64p(maxTelemetryCount + 1), // legit cumulative ns, above the count cap
				IsolatedPrefillTPS:  &tps,
			}}},
			Telemetry: &protocol.CapacityTelemetry{InAdmission: i64p(-1), MemoryPressureLevel: "plaid"},
		}
	}

	bc := mk(25_000)
	clampBackendCapacity(logger, "p1", bc)
	st := bc.Slots[0].Telemetry
	for name, tc := range map[string]struct{ got, want int64 }{
		"negative count → 0":        {*st.QueuedPrefillTokens, 0},
		"count cap":                 {*st.PrefillTokensTotal, maxTelemetryCount},
		"bytes cap":                 {*st.KVBytesInUse, maxTelemetryBytes},
		"ms cap":                    {*st.EvalInFlightMS, maxTelemetryMS},
		"ns total keeps wide bound": {*st.StepWallNSTotal, maxTelemetryCount + 1},
		"capacity negative → 0":     {*bc.Telemetry.InAdmission, 0},
	} {
		if tc.got != tc.want {
			t.Errorf("%s: got %d, want %d", name, tc.got, tc.want)
		}
	}
	if *st.IsolatedPrefillTPS != maxTelemetryTPS {
		t.Errorf("tps over cap = %v, want %v", *st.IsolatedPrefillTPS, maxTelemetryTPS)
	}
	if st.PartialPrefillRows != nil || st.EWMAInitialized != nil {
		t.Error("absent telemetry fields must stay nil after clamping")
	}
	if bc.Telemetry.MemoryPressureLevel != protocol.MemoryPressureOther {
		t.Errorf("memory_pressure_level = %q, want other", bc.Telemetry.MemoryPressureLevel)
	}
	for name, tps := range map[string]float64{"NaN": math.NaN(), "+Inf": math.Inf(1), "-Inf": math.Inf(-1)} {
		bc := mk(tps)
		clampBackendCapacity(logger, "p1", bc)
		if bc.Slots[0].Telemetry.IsolatedPrefillTPS != nil {
			t.Errorf("tps %s should read as not reported (nil)", name)
		}
	}
	// No telemetry at all (legacy provider) must not panic or grow a sub-object.
	legacy := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "qwen"}}}
	clampBackendCapacity(logger, "p1", legacy)
	if legacy.Telemetry != nil || legacy.Slots[0].Telemetry != nil {
		t.Error("clamp invented telemetry on a legacy heartbeat")
	}
}

// Both copy paths must own their Telemetry pointees: mutating the source after
// the copy (or clamping the copy) must not leak across.
func TestHeartbeatTelemetryIsDeepCloned(t *testing.T) {
	src := &protocol.BackendCapacity{
		Slots:     []protocol.BackendSlotCapacity{{Model: "qwen", Telemetry: &protocol.SlotTelemetry{QueuedPrefillTokens: i64p(5)}}},
		Telemetry: &protocol.CapacityTelemetry{InflightTasks: i64p(3), MemoryPressureLevel: protocol.MemoryPressureNormal},
	}
	_, _, canonical := canonicalHeartbeatModelState([]protocol.ModelInfo{{ID: "qwen"}}, nil, nil, src)
	snapshot := (&Provider{BackendCapacity: src}).BackendCapacitySnapshot()
	*src.Slots[0].Telemetry.QueuedPrefillTokens = 99
	*src.Telemetry.InflightTasks = 99
	src.Telemetry.MemoryPressureLevel = "plaid"
	for name, got := range map[string]*protocol.BackendCapacity{"canonical": canonical, "snapshot": snapshot} {
		if got.Slots[0].Telemetry == src.Slots[0].Telemetry || got.Telemetry == src.Telemetry {
			t.Fatalf("%s shares the Telemetry pointer with the source", name)
		}
		if *got.Slots[0].Telemetry.QueuedPrefillTokens != 5 || *got.Telemetry.InflightTasks != 3 ||
			got.Telemetry.MemoryPressureLevel != protocol.MemoryPressureNormal {
			t.Fatalf("%s copy changed with the source: %+v / %+v", name, got.Slots[0].Telemetry, got.Telemetry)
		}
	}
}
