package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func registerCapacityBenchmarkProvider(
	t *testing.T,
	reg *Registry,
	id, model string,
	bandwidth, fallbackTPS, observedTPS float64,
	privateOnly bool,
	templateOK *bool,
) {
	t.Helper()
	msg := testRegisterMessage()
	msg.Hardware.MemoryBandwidthGBs = bandwidth
	msg.Models = []protocol.ModelInfo{{
		ID:               model,
		ModelType:        "chat",
		TemplateRenderOK: templateOK,
	}}
	msg.PrivateOnly = privateOnly
	p := reg.Register(id, nil, msg)
	p.mu.Lock()
	testMakeTextRoutable(p)
	p.RuntimeVerified = true
	p.DecodeTPS = fallbackTPS
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                model,
			State:                "idle",
			MaxConcurrency:       4,
			ActiveTokenBudgetMax: 4096,
			ObservedDecodeTPS:    observedTPS,
		}},
	}
	p.mu.Unlock()
}

func TestModelCapacitySnapshotAggregatesBandwidthAndObservedBenchmark(t *testing.T) {
	reg := New(testLogger())
	const model = "earnings-capacity-model"
	ok := true
	broken := false

	registerCapacityBenchmarkProvider(t, reg, "observed-a", model, 400, 10, 100, false, &ok)
	registerCapacityBenchmarkProvider(t, reg, "observed-b", model, 200, 10, 50, false, &ok)
	registerCapacityBenchmarkProvider(t, reg, "unobserved", model, 100, 30, 0, false, &ok)
	registerCapacityBenchmarkProvider(t, reg, "private", model, 800, 500, 500, true, &ok)
	registerCapacityBenchmarkProvider(t, reg, "broken-template", model, 600, 400, 400, false, &broken)

	var got *ModelCapacity
	for _, capacity := range reg.ModelCapacitySnapshot() {
		if capacity.ModelID == model {
			c := capacity
			got = &c
			break
		}
	}
	if got == nil {
		t.Fatal("model capacity missing")
	}
	if got.EligibleProviders != 3 {
		t.Fatalf("EligibleProviders = %d, want 3", got.EligibleProviders)
	}
	if got.AggregateTPS != 180 {
		t.Fatalf("AggregateTPS = %.1f, want 180", got.AggregateTPS)
	}
	if got.AggregateMemoryBandwidthGBs != 700 {
		t.Fatalf("AggregateMemoryBandwidthGBs = %.1f, want 700", got.AggregateMemoryBandwidthGBs)
	}
	if got.BenchmarkTPS != 150 || got.BenchmarkMemoryBandwidthGBs != 600 {
		t.Fatalf(
			"benchmark = %.1f TPS / %.1f GB/s, want 150 / 600",
			got.BenchmarkTPS,
			got.BenchmarkMemoryBandwidthGBs,
		)
	}
}
