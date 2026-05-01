package registry

import "testing"

func TestRoutingReplaySimulatorRiotLessonStaleMetricHerdsWhileRoundRobinSpreads(t *testing.T) {
	model := "riot-lesson-model"
	scenario := RoutingReplayScenario{
		Providers: []RoutingReplayProvider{
			{ID: "p0", Model: model, DecodeTPS: 100, PrefillTPS: 400, MaxConcurrency: 2, CPUUsage: 0.10, MemoryPressure: 0.10, ThermalState: "nominal"},
			{ID: "p1", Model: model, DecodeTPS: 100, PrefillTPS: 400, MaxConcurrency: 2, CPUUsage: 0.50, MemoryPressure: 0.10, ThermalState: "nominal"},
			{ID: "p2", Model: model, DecodeTPS: 100, PrefillTPS: 400, MaxConcurrency: 2, CPUUsage: 0.50, MemoryPressure: 0.10, ThermalState: "nominal"},
		},
		Requests: burstRequests(model, 6, 0, 100, 200, 1_000),
		Strategies: []RoutingReplayStrategy{
			RoutingStrategyLeastMetric,
			RoutingStrategyRoundRobin,
		},
	}

	results := ReplayRoutingScenario(scenario)
	leastMetric := results[RoutingStrategyLeastMetric]
	roundRobin := results[RoutingStrategyRoundRobin]

	if got := leastMetric.ProviderRequestCounts["p0"]; got != 6 {
		t.Fatalf("stale least_metric routed %d requests to p0, want 6-request herd", got)
	}
	if leastMetric.ProviderRequestCounts["p1"] != 0 || leastMetric.ProviderRequestCounts["p2"] != 0 {
		t.Fatalf("stale least_metric should not spread: counts=%v", leastMetric.ProviderRequestCounts)
	}
	if leastMetric.OverCapacityCount != 4 {
		t.Fatalf("least_metric over-capacity count=%d, want 4", leastMetric.OverCapacityCount)
	}
	if leastMetric.TimeoutCount == 0 {
		t.Fatal("least_metric should produce TTFT timeouts when stale CPU herds the burst")
	}

	for _, id := range []string{"p0", "p1", "p2"} {
		if got := roundRobin.ProviderRequestCounts[id]; got != 2 {
			t.Fatalf("round_robin count for %s=%d, want 2 (counts=%v)", id, got, roundRobin.ProviderRequestCounts)
		}
	}
	if roundRobin.OverCapacityCount != 0 {
		t.Fatalf("round_robin over-capacity count=%d, want 0", roundRobin.OverCapacityCount)
	}
	if roundRobin.TimeoutCount != 0 {
		t.Fatalf("round_robin timeout count=%d, want 0", roundRobin.TimeoutCount)
	}
	if !(leastMetric.TTFTP95Ms > roundRobin.TTFTP95Ms) {
		t.Fatalf("expected least_metric p95 TTFT (%f) > round_robin (%f)", leastMetric.TTFTP95Ms, roundRobin.TTFTP95Ms)
	}
}

func TestRoutingReplaySimulatorCurrentCostModelDeterministicComparison(t *testing.T) {
	model := "cost-model-replay"
	scenario := RoutingReplayScenario{
		Providers: []RoutingReplayProvider{
			{ID: "fast", Model: model, DecodeTPS: 100, PrefillTPS: 400, MaxConcurrency: 2, CPUUsage: 0.10, MemoryPressure: 0.10, ThermalState: "nominal"},
			{ID: "slow", Model: model, DecodeTPS: 80, PrefillTPS: 320, MaxConcurrency: 2, CPUUsage: 0.10, MemoryPressure: 0.10, ThermalState: "nominal"},
		},
		Requests: burstRequests(model, 4, 0, 100, 200, 10_000),
		Strategies: []RoutingReplayStrategy{
			RoutingStrategyCurrentCostModel,
			RoutingStrategyLeastActive,
		},
	}

	first := ReplayRoutingScenario(scenario)
	second := ReplayRoutingScenario(scenario)

	costA := first[RoutingStrategyCurrentCostModel]
	costB := second[RoutingStrategyCurrentCostModel]
	if len(costA.Assignments) != len(costB.Assignments) {
		t.Fatalf("assignment lengths differ: %d vs %d", len(costA.Assignments), len(costB.Assignments))
	}
	for i := range costA.Assignments {
		if costA.Assignments[i].ProviderID != costB.Assignments[i].ProviderID {
			t.Fatalf("current cost model assignment %d not deterministic: %q vs %q", i, costA.Assignments[i].ProviderID, costB.Assignments[i].ProviderID)
		}
	}
	if got := costA.ProviderRequestCounts["fast"]; got != 2 {
		t.Fatalf("current cost model fast count=%d, want 2 (counts=%v assignments=%v)", got, costA.ProviderRequestCounts, costA.Assignments)
	}
	if got := costA.ProviderRequestCounts["slow"]; got != 2 {
		t.Fatalf("current cost model slow count=%d, want 2 (counts=%v assignments=%v)", got, costA.ProviderRequestCounts, costA.Assignments)
	}
	if costA.TTFTP50Ms <= 0 || costA.TTFTP95Ms <= 0 || costA.TTFTP99Ms <= 0 {
		t.Fatalf("TTFT percentiles must be populated: %+v", costA)
	}
	if costA.TotalLatencyP50Ms <= 0 || costA.TotalLatencyP95Ms <= 0 || costA.TotalLatencyP99Ms <= 0 || costA.TotalLatencyMs <= 0 {
		t.Fatalf("latency metrics must be populated: %+v", costA)
	}
	if len(costA.ProviderUtilization) != 2 || costA.ProviderUtilization["fast"] <= 0 || costA.ProviderUtilization["slow"] <= 0 {
		t.Fatalf("provider utilization must be populated: %+v", costA.ProviderUtilization)
	}
}

func burstRequests(model string, n int, arrivalMs float64, promptTokens, maxTokens int, timeoutMs float64) []RoutingReplayRequest {
	reqs := make([]RoutingReplayRequest, 0, n)
	for i := 0; i < n; i++ {
		reqs = append(reqs, RoutingReplayRequest{
			ID:           string(rune('a' + i)),
			Model:        model,
			ArrivalMs:    arrivalMs,
			PromptTokens: promptTokens,
			MaxTokens:    maxTokens,
			TimeoutMs:    timeoutMs,
		})
	}
	return reqs
}
