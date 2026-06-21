package baserewards

import (
	"reflect"
	"testing"
)

func grantedByKey(allocs []Allocation) map[string]int64 {
	m := make(map[string]int64, len(allocs))
	for _, a := range allocs {
		m[a.ProviderKey] = a.Granted
	}
	return m
}

func sumGranted(allocs []Allocation) int64 {
	var s int64
	for _, a := range allocs {
		s += a.Granted
	}
	return s
}

func TestAllocateDraws_UnderBudget(t *testing.T) {
	cands := []Candidate{
		{ProviderKey: "a", AccountID: "acc-a", MemGB: 64, Floor: 18_000_000, Draw: 18_000_000},
		{ProviderKey: "b", AccountID: "acc-b", MemGB: 96, Floor: 22_000_000, Draw: 22_000_000},
	}
	allocs := AllocateDraws(cands, FloorPoolBudgetMicroUSD, FloorPoolBudgetMicroUSD, 0.5, 0.05, nil)
	g := grantedByKey(allocs)
	if g["a"] != 18_000_000 || g["b"] != 22_000_000 {
		t.Fatalf("under-budget: every desired draw should be granted in full, got %+v", g)
	}
	if total := sumGranted(allocs); total > FloorPoolBudgetMicroUSD {
		t.Fatalf("Σ granted %d exceeds budget %d", total, FloorPoolBudgetMicroUSD)
	}
}

func TestAllocateDraws_WorkhorseProtected(t *testing.T) {
	// One idle 512GB box wants the entire budget; one idle 64GB workhorse wants
	// a slice. With a tiny budget that cannot fund both fully, the workhorse must
	// not be starved by the bigger machine.
	budget := int64(30_000_000) // smaller than the 512 box's desired draw alone
	cands := []Candidate{
		{ProviderKey: "big", AccountID: "acc-big", MemGB: 512, Floor: 40_000_000, Draw: 40_000_000},
		{ProviderKey: "work", AccountID: "acc-work", MemGB: 64, Floor: 18_000_000, Draw: 18_000_000},
	}
	allocs := AllocateDraws(cands, budget, budget, 0.5, 0, nil) // 50% reserved for workhorse, no per-account cap
	g := grantedByKey(allocs)

	if g["work"] == 0 {
		t.Fatalf("workhorse was starved: %+v", g)
	}
	// The reserved sub-pool (50% of 30M = 15M) guarantees the workhorse at least
	// that much (its desired 18M exceeds the reserve, so it gets the full 15M).
	if g["work"] < 15_000_000 {
		t.Fatalf("workhorse got %d, want >= reserved 15_000_000: %+v", g["work"], g)
	}
	if total := sumGranted(allocs); total > budget {
		t.Fatalf("Σ granted %d exceeds budget %d", total, budget)
	}
}

func TestAllocateDraws_PerAccountCap(t *testing.T) {
	// Three machines on one account, plenty of budget, but a 5% per-account cap.
	budget := int64(100_000_000)
	cap := int64(float64(budget) * 0.05) // 5_000_000
	cands := []Candidate{
		{ProviderKey: "a1", AccountID: "whale", MemGB: 64, Floor: 18_000_000, Draw: 18_000_000},
		{ProviderKey: "a2", AccountID: "whale", MemGB: 64, Floor: 18_000_000, Draw: 18_000_000},
		{ProviderKey: "a3", AccountID: "whale", MemGB: 64, Floor: 18_000_000, Draw: 18_000_000},
	}
	allocs := AllocateDraws(cands, budget, budget, 0.5, 0.05, nil)
	var accTotal int64
	for _, a := range allocs {
		if a.AccountID == "whale" {
			accTotal += a.Granted
		}
	}
	if accTotal > cap {
		t.Fatalf("account total %d exceeds per-account cap %d", accTotal, cap)
	}
	if accTotal != cap {
		t.Fatalf("account total %d should saturate the cap %d (ample demand)", accTotal, cap)
	}
}

// TestAllocateDraws_PerAccountCapAcrossRuns is the regression for the cap leak
// across re-settlement runs: an account that already drew this period must have
// that prior amount counted against its 5% cap, so a newly-eligible machine on
// the same account can only draw the remaining headroom.
func TestAllocateDraws_PerAccountCapAcrossRuns(t *testing.T) {
	const pool = int64(100_000_000) // 5% cap = 5_000_000
	// "whale" already settled 4M in an earlier run of this period.
	prior := map[string]int64{"whale": 4_000_000}
	cands := []Candidate{
		{ProviderKey: "a2", AccountID: "whale", MemGB: 64, Floor: 18_000_000, Draw: 18_000_000},
	}
	// budget (remaining this run) is the full pool minus the 4M already spent.
	allocs := AllocateDraws(cands, pool-4_000_000, pool, 0.5, 0.05, prior)
	if got := allocs[0].Granted; got != 1_000_000 {
		t.Fatalf("granted %d, want 1000000 (5%% cap 5M minus 4M prior)", got)
	}
}

func TestAllocateDraws_Deterministic(t *testing.T) {
	cands := []Candidate{
		{ProviderKey: "c", AccountID: "acc-c", MemGB: 512, Floor: 40_000_000, Draw: 40_000_000},
		{ProviderKey: "a", AccountID: "acc-a", MemGB: 64, Floor: 18_000_000, Draw: 18_000_000},
		{ProviderKey: "b", AccountID: "acc-b", MemGB: 96, Floor: 22_000_000, Draw: 22_000_000},
		{ProviderKey: "d", AccountID: "acc-d", MemGB: 64, Floor: 18_000_000, Draw: 18_000_000},
	}
	budget := int64(25_000_000) // binds — forces ranking decisions
	first := AllocateDraws(cands, budget, budget, 0.5, 0.05, nil)

	// Re-run with a shuffled input order; result-by-key must be identical.
	shuffled := []Candidate{cands[2], cands[0], cands[3], cands[1]}
	second := AllocateDraws(shuffled, budget, budget, 0.5, 0.05, nil)

	if !reflect.DeepEqual(grantedByKey(first), grantedByKey(second)) {
		t.Fatalf("allocation not deterministic across input order:\n first=%+v\n second=%+v",
			grantedByKey(first), grantedByKey(second))
	}
	if total := sumGranted(first); total > budget {
		t.Fatalf("Σ granted %d exceeds budget %d", total, budget)
	}
}

func TestValuePerFloorDollar_WorkhorseBoost(t *testing.T) {
	// A fully-idle workhorse outranks a fully-idle big box.
	work := Candidate{MemGB: 64, Floor: 18_000_000, Earned: 0}
	big := Candidate{MemGB: 512, Floor: 40_000_000, Earned: 0}
	if valuePerFloorDollar(work) <= valuePerFloorDollar(big) {
		t.Fatalf("workhorse %v should outrank big box %v",
			valuePerFloorDollar(work), valuePerFloorDollar(big))
	}
	// Within the same class, lower earned-coverage outranks higher.
	idle := Candidate{MemGB: 64, Floor: 18_000_000, Earned: 0}
	busy := Candidate{MemGB: 64, Floor: 18_000_000, Earned: 9_000_000}
	if valuePerFloorDollar(idle) <= valuePerFloorDollar(busy) {
		t.Fatalf("idle %v should outrank busy %v",
			valuePerFloorDollar(idle), valuePerFloorDollar(busy))
	}
}
