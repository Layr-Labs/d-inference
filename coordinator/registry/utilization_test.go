package registry

import (
	"testing"
	"time"
)

// approx reuses the package's approxEqual helper with a fixed tolerance.
func approx(a, b float64) bool { return approxEqual(a, b, 1e-6) }

func TestComputeNetworkUtilization_WarmAndTokenAxes(t *testing.T) {
	now := time.Now()
	snapAt := now.Add(-5 * time.Second)
	caps := []ModelCapacity{
		{
			ModelID:              "hot",
			WarmProviders:        4,
			RunningProviders:     3,
			ColdProviders:        1,
			ActiveRequests:       12,
			QueuedRequests:       2,
			AggregateTPS:         800,
			TokenBudgetTotal:     1000,
			TokenBudgetRemaining: 600, // 40% used (per-model row)
		},
		{
			ModelID:              "idle",
			WarmProviders:        10,
			RunningProviders:     0,
			ColdProviders:        2,
			AggregateTPS:         200,
			TokenBudgetTotal:     1000,
			TokenBudgetRemaining: 1000, // 0% used (per-model row)
		},
	}
	snaps := []WarmPoolSnapshot{
		// hot: demand 12, serving = 4 warm × 5 quality = 20 -> warm util 0.6
		{Model: "hot", WarmProviders: 4, QualityConcurrency: 5, DemandConcurrency: 12, TargetWarm: 6, SpillArrivalRate: 1.5},
		// idle: demand 0, serving = 10 × 4 = 40 -> warm util 0
		{Model: "idle", WarmProviders: 10, QualityConcurrency: 4, DemandConcurrency: 0, TargetWarm: 10},
	}
	// Provider-deduped fleet figures (NOT the per-model sums).
	fleet := FleetCapacity{DecodeTPS: 1000, BudgetUsed: 400, BudgetTotal: 2000}

	got := computeNetworkUtilization(caps, snaps, fleet, snapAt, now)

	// Aggregate warm util = Σdemand/Σserving = 12 / (20+40) = 0.2
	if !approx(got.WarmUtilization, 0.2) {
		t.Fatalf("warm utilization = %v, want 0.2", got.WarmUtilization)
	}
	// Network token-budget util comes from the deduped fleet = 400/2000 = 0.2
	if !approx(got.TokenBudgetUtilization, 0.2) {
		t.Fatalf("token-budget utilization = %v, want 0.2", got.TokenBudgetUtilization)
	}
	// Headline = max(0.2, 0.2) = 0.2
	if !approx(got.Utilization, 0.2) {
		t.Fatalf("headline utilization = %v, want 0.2", got.Utilization)
	}
	// Bottleneck = hot model's per-model util = max(warm 0.6, token 0.4) = 0.6
	if !approx(got.BottleneckUtilization, 0.6) || got.BottleneckModel != "hot" {
		t.Fatalf("bottleneck = %v (%s), want 0.6 (hot)", got.BottleneckUtilization, got.BottleneckModel)
	}
	// CapacityTPS is the deduped fleet figure, not 800+200.
	if got.CapacityTPS != 1000 {
		t.Fatalf("capacity tps = %v, want 1000 (fleet)", got.CapacityTPS)
	}
	if got.ActiveRequests != 12 || got.QueuedRequests != 2 {
		t.Fatalf("active/queued = %d/%d, want 12/2", got.ActiveRequests, got.QueuedRequests)
	}
	if !approx(got.SpillArrivalRate, 1.5) {
		t.Fatalf("spill = %v, want 1.5", got.SpillArrivalRate)
	}
	if !got.HasWarmPoolData || got.WarmDataAgeSecs < 4 || got.WarmDataAgeSecs > 6 {
		t.Fatalf("warm data flags wrong: has=%v age=%v", got.HasWarmPoolData, got.WarmDataAgeSecs)
	}
	if len(got.Models) != 2 {
		t.Fatalf("expected 2 model rows, got %d", len(got.Models))
	}
}

// TestComputeNetworkUtilization_FleetDedup proves the network throughput and
// token-budget aggregates come from the deduped fleet figures, not from summing
// per-model rows (which double-counts a provider advertising multiple models).
func TestComputeNetworkUtilization_FleetDedup(t *testing.T) {
	now := time.Now()
	// Two model rows that, in prod, are produced by the SAME multi-model
	// provider: each row carries that provider's full decode TPS and budget.
	caps := []ModelCapacity{
		{ModelID: "a", AggregateTPS: 500, TokenBudgetTotal: 1000, TokenBudgetRemaining: 0},
		{ModelID: "b", AggregateTPS: 500, TokenBudgetTotal: 1000, TokenBudgetRemaining: 0},
	}
	// Deduped fleet: one provider -> 500 TPS, one shared 1000-token pool fully used.
	fleet := FleetCapacity{DecodeTPS: 500, BudgetUsed: 1000, BudgetTotal: 1000}
	got := computeNetworkUtilization(caps, nil, fleet, time.Time{}, now)
	if got.CapacityTPS != 500 {
		t.Fatalf("capacity tps = %v, want 500 (deduped, not 1000)", got.CapacityTPS)
	}
	if !approx(got.TokenBudgetUtilization, 1) {
		t.Fatalf("token util = %v, want 1.0 (deduped 1000/1000, not 2000 denom)", got.TokenBudgetUtilization)
	}
}

func TestComputeNetworkUtilization_NoWarmDataFallsBackToTokenBudget(t *testing.T) {
	now := time.Now()
	caps := []ModelCapacity{
		{ModelID: "m", WarmProviders: 2, TokenBudgetTotal: 1000, TokenBudgetRemaining: 250}, // 75% used
	}
	fleet := FleetCapacity{BudgetUsed: 750, BudgetTotal: 1000}
	got := computeNetworkUtilization(caps, nil, fleet, time.Time{}, now)
	if got.HasWarmPoolData {
		t.Fatalf("expected no warm-pool data")
	}
	if !approx(got.Utilization, 0.75) {
		t.Fatalf("headline = %v, want 0.75 (token budget)", got.Utilization)
	}
	if got.Models[0].HasWarmData {
		t.Fatalf("model should not have warm data")
	}
	// Per-model row still computes its own token util.
	if !approx(got.Models[0].TokenBudgetUtilization, 0.75) {
		t.Fatalf("per-model token util = %v, want 0.75", got.Models[0].TokenBudgetUtilization)
	}
}

func TestComputeNetworkUtilization_ClampsAndGuards(t *testing.T) {
	now := time.Now()
	caps := []ModelCapacity{
		// Oversubscribed: demand 100, serving 4 -> warm util 25, headline clamps to 1.
		{ModelID: "over", TokenBudgetTotal: 0, TokenBudgetRemaining: 0},
	}
	snaps := []WarmPoolSnapshot{
		{Model: "over", WarmProviders: 2, QualityConcurrency: 2, DemandConcurrency: 100},
	}
	got := computeNetworkUtilization(caps, snaps, FleetCapacity{}, now, now)
	if got.Utilization != 1 {
		t.Fatalf("headline = %v, want clamped 1", got.Utilization)
	}
	if got.Models[0].Utilization != 1 {
		t.Fatalf("per-model headline = %v, want clamped 1", got.Models[0].Utilization)
	}
	// Raw warm utilization stays uncapped for drill-down.
	if !approx(got.WarmUtilization, 25) {
		t.Fatalf("raw warm util = %v, want 25", got.WarmUtilization)
	}
}

func TestComputeNetworkUtilization_ColdModelWithDemandIsSaturated(t *testing.T) {
	now := time.Now()
	caps := []ModelCapacity{
		{ModelID: "cold", WarmProviders: 0, ColdProviders: 5, TokenBudgetTotal: 0},
	}
	snaps := []WarmPoolSnapshot{
		// No warm providers, but queued/spilled demand exists -> saturated.
		{Model: "cold", WarmProviders: 0, QualityConcurrency: 4, DemandConcurrency: 3, SpillArrivalRate: 2},
	}
	got := computeNetworkUtilization(caps, snaps, FleetCapacity{}, now, now)
	if got.Models[0].WarmUtilization != 1 {
		t.Fatalf("per-model warm util = %v, want 1 (saturated cold model)", got.Models[0].WarmUtilization)
	}
	if got.Models[0].Utilization != 1 {
		t.Fatalf("per-model headline = %v, want 1", got.Models[0].Utilization)
	}
	if got.BottleneckModel != "cold" || got.BottleneckUtilization != 1 {
		t.Fatalf("bottleneck = %s/%v, want cold/1", got.BottleneckModel, got.BottleneckUtilization)
	}
	// The network headline must also read saturated (not 0) when the whole
	// fleet is cold but demand exists — the cold-start-storm case.
	if got.Utilization != 1 {
		t.Fatalf("network headline = %v, want 1 (cold-start storm)", got.Utilization)
	}
	if !approx(got.WarmUtilization, 1) {
		t.Fatalf("aggregate warm util = %v, want 1", got.WarmUtilization)
	}
}

func TestComputeNetworkUtilization_WarmCountFallback(t *testing.T) {
	now := time.Now()
	caps := []ModelCapacity{
		{ModelID: "m", WarmProviders: 8, TokenBudgetTotal: 0},
	}
	// Snapshot reports 0 warm providers -> fall back to capacity warm count (8).
	snaps := []WarmPoolSnapshot{
		{Model: "m", WarmProviders: 0, QualityConcurrency: 2, DemandConcurrency: 4},
	}
	got := computeNetworkUtilization(caps, snaps, FleetCapacity{}, now, now)
	m := got.Models[0]
	if m.WarmProviders != 8 {
		t.Fatalf("reported warm = %d, want 8 (fallback)", m.WarmProviders)
	}
	// serving = 8 × 2 = 16, util = 4/16 = 0.25, and reported warm reproduces it.
	if m.ServingCapacity != 16 || !approx(m.WarmUtilization, 0.25) {
		t.Fatalf("serving=%v warmUtil=%v, want 16 / 0.25", m.ServingCapacity, m.WarmUtilization)
	}
}

func TestComputeNetworkUtilization_NoWarmDataAge(t *testing.T) {
	now := time.Now()
	caps := []ModelCapacity{{ModelID: "m", TokenBudgetTotal: 100, TokenBudgetRemaining: 100}}
	// snapAt non-zero but no snapshots -> has-data false and age stays 0.
	got := computeNetworkUtilization(caps, nil, FleetCapacity{}, now.Add(-30*time.Second), now)
	if got.HasWarmPoolData {
		t.Fatalf("expected has_warm_pool_data=false")
	}
	if got.WarmDataAgeSecs != 0 {
		t.Fatalf("warm data age = %v, want 0 when no snapshots", got.WarmDataAgeSecs)
	}
}

func TestComputeNetworkUtilization_DegenerateTokenBudgetRowGuarded(t *testing.T) {
	now := time.Now()
	caps := []ModelCapacity{
		// Degenerate: Total 0 but Remaining negative would yield used>0; the
		// per-model row must guard it (0 util, 0 used) and not panic.
		{ModelID: "bad", TokenBudgetTotal: 0, TokenBudgetRemaining: -50},
		{ModelID: "ok", TokenBudgetTotal: 1000, TokenBudgetRemaining: 500},
	}
	fleet := FleetCapacity{BudgetUsed: 500, BudgetTotal: 1000}
	got := computeNetworkUtilization(caps, nil, fleet, time.Time{}, now)
	// Network util from deduped fleet = 0.5.
	if !approx(got.TokenBudgetUtilization, 0.5) {
		t.Fatalf("network token util = %v, want 0.5 (fleet)", got.TokenBudgetUtilization)
	}
	// Degenerate per-model row stays zeroed.
	var bad ModelUtilization
	for _, m := range got.Models {
		if m.Model == "bad" {
			bad = m
		}
	}
	if bad.TokenBudgetUtilization != 0 || bad.TokenBudgetUsed != 0 {
		t.Fatalf("degenerate row = util %v used %d, want 0/0", bad.TokenBudgetUtilization, bad.TokenBudgetUsed)
	}
}

func TestComputeNetworkUtilization_Empty(t *testing.T) {
	got := computeNetworkUtilization(nil, nil, FleetCapacity{}, time.Time{}, time.Now())
	if got.Utilization != 0 || got.CapacityTPS != 0 || len(got.Models) != 0 {
		t.Fatalf("empty snapshot should be zero-valued, got %+v", got)
	}
}
