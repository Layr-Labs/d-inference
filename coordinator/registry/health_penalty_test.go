package registry

import (
	"fmt"
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestHealthPenaltyMs pins the routing health term. Memory pressure, CPU, and
// thermal state are latency signals and keep their prices. The active-memory
// fraction (gpuActiveGB/totalMemGB) is the resident-weights fraction on an
// idle box — a size ratio, not a latency signal; its KV growth is already
// priced by the backlog/budget terms — so it is priced at zero. Fails before
// the change on the 26-of-36 GB case (3611 ms).
func TestHealthPenaltyMs(t *testing.T) {
	cases := []struct {
		name        string
		metrics     protocol.SystemMetrics
		gpuActiveGB float64
		totalMemGB  float64
		want        float64
	}{
		{name: "nominal idle", metrics: protocol.SystemMetrics{ThermalState: "nominal"}},
		{
			name:        "resident weights 26 of 36 GB",
			metrics:     protocol.SystemMetrics{ThermalState: "nominal"},
			gpuActiveGB: 26, totalMemGB: 36,
		},
		{
			name:        "resident weights 26 of 128 GB",
			metrics:     protocol.SystemMetrics{ThermalState: "nominal"},
			gpuActiveGB: 26, totalMemGB: 128,
		},
		{
			name:        "active memory above total",
			metrics:     protocol.SystemMetrics{ThermalState: "nominal"},
			gpuActiveGB: 40, totalMemGB: 36,
		},
		{name: "thermal fair", metrics: protocol.SystemMetrics{ThermalState: "fair"}, want: 2000},
		{name: "thermal serious", metrics: protocol.SystemMetrics{ThermalState: "serious"}, want: 8000},
		{name: "memory pressure 0.25", metrics: protocol.SystemMetrics{MemoryPressure: 0.25}, want: 1000},
		{name: "memory pressure 1.0", metrics: protocol.SystemMetrics{MemoryPressure: 1}, want: 4000},
		{name: "cpu 1.0", metrics: protocol.SystemMetrics{CPUUsage: 1}, want: 1500},
		{
			name: "busy small box: pressure, cpu, fair, resident weights",
			metrics: protocol.SystemMetrics{
				MemoryPressure: 0.85, CPUUsage: 0.1, ThermalState: "fair",
			},
			gpuActiveGB: 26, totalMemGB: 36,
			want: 0.85*4000 + 0.1*1500 + 2000,
		},
	}
	for _, tc := range cases {
		got := healthPenaltyMs(tc.metrics, tc.gpuActiveGB, tc.totalMemGB)
		if math.Abs(got-tc.want) > 1e-9 {
			t.Errorf("%s: healthPenaltyMs = %.3f ms, want %.3f ms", tc.name, got, tc.want)
		}
	}
}

// TestNearTieAdmitsSmallBoxWithResidentWeights drives the real scheduler with
// two providers identical except total RAM (32 vs 128 GB), both holding the
// same resident 26 GB model with a healthy thermal state, and pins that they
// rank the same: equal health term, both inside the near-tie window, and the
// small box winning its share of the random spread. Before the change the
// 26/32 box carried 4062 ms of active-memory penalty against the 128 GB box's
// 1016 ms — a 3047 ms gap outside the 3000 ms window — so the near-tie pool
// was 1 and the small box won 0 of 1000.
func TestNearTieAdmitsSmallBoxWithResidentWeights(t *testing.T) {
	reg := New(testLogger())
	const model = "model"
	small := makeSchedulerProvider(t, reg, "small-32gb", model, 50)
	large := makeSchedulerProvider(t, reg, "large-128gb", model, 50)
	for p, totalGB := range map[*Provider]float64{small: 32, large: 128} {
		p.mu.Lock()
		p.BackendCapacity.TotalMemoryGB = totalGB
		p.BackendCapacity.GPUMemoryActiveGB = 26
		p.mu.Unlock()
	}

	const rounds = 1000
	wins := map[string]int{}
	health := map[string]float64{}
	for i := 0; i < rounds; i++ {
		pr := &PendingRequest{
			RequestID: fmt.Sprintf("near-tie-%d", i), Model: model, RequestedMaxTokens: 256,
		}
		p, decision := reg.ReserveProviderEx(model, pr)
		if p == nil {
			t.Fatalf("round %d: no provider reserved", i)
		}
		if decision.NearTiePoolSize != 2 {
			t.Fatalf("round %d: near-tie pool = %d, want 2 (winner %s cost %.0f ms health %.0f ms)",
				i, decision.NearTiePoolSize, p.ID, decision.CostMs, decision.HealthMs)
		}
		wins[p.ID]++
		health[p.ID] = decision.HealthMs
		p.RemovePending(pr.RequestID)
	}
	if wins[small.ID] == 0 || wins[large.ID] == 0 {
		t.Fatalf("one box never won: %v", wins)
	}
	if health[small.ID] != health[large.ID] {
		t.Fatalf("health term differs by resident-weights fraction: small %.0f ms, large %.0f ms",
			health[small.ID], health[large.ID])
	}
	if share := float64(wins[small.ID]) / rounds; share < 0.35 || share > 0.65 {
		t.Fatalf("small box won %d of %d (%.0f%%), want 35-65%% of the near-tie spread",
			wins[small.ID], rounds, share*100)
	}
}
