package registry

import (
	"testing"
	"time"
)

var placementNow = time.Unix(1_700_000_000, 0)

func capable(models ...string) map[string]float64 {
	m := make(map[string]float64, len(models))
	for _, x := range models {
		m[x] = 50 // representative decode tps
	}
	return m
}

func actionMap(plan placementPlan) map[string]string {
	out := map[string]string{}
	for _, a := range plan.actions {
		out[a.machineID] = a.model
	}
	return out
}

func TestPlanPlacementAssignsUnmanagedToDemand(t *testing.T) {
	models := []placementModel{{model: "A", need: 2}, {model: "B", need: 1}}
	machines := []placementMachine{
		{id: "m1", current: "", idle: true, capable: capable("A", "B")},
		{id: "m2", current: "", idle: true, capable: capable("A", "B")},
		{id: "m3", current: "", idle: true, capable: capable("A", "B")},
	}
	plan := planPlacement(models, machines, 5*time.Minute, 10, placementNow)
	if plan.desired["A"] != 2 || plan.desired["B"] != 1 {
		t.Fatalf("desired=%v, want A:2 B:1", plan.desired)
	}
	if len(plan.actions) != 3 {
		t.Fatalf("expected 3 assignments, got %d (%v)", len(plan.actions), plan.actions)
	}
	// Every machine ends assigned; pool sizes match desired.
	if plan.current["A"] != 2 || plan.current["B"] != 1 {
		t.Fatalf("current after plan=%v, want A:2 B:1", plan.current)
	}
}

func TestPlanPlacementNormalizesByPriorityWhenOversubscribed(t *testing.T) {
	// Demand (5) exceeds the fleet (3). High-priority A should win the extra
	// machines, but B's floor of 1 must still be honored (no starvation).
	models := []placementModel{
		{model: "A", need: 4, priority: 10},
		{model: "B", need: 1, floor: 1, priority: 1},
	}
	machines := []placementMachine{
		{id: "m1", current: "", idle: true, capable: capable("A", "B")},
		{id: "m2", current: "", idle: true, capable: capable("A", "B")},
		{id: "m3", current: "", idle: true, capable: capable("A", "B")},
	}
	plan := planPlacement(models, machines, 5*time.Minute, 10, placementNow)
	if plan.desired["A"] != 2 || plan.desired["B"] != 1 {
		t.Fatalf("desired=%v, want A:2 B:1 (B floor honored, A gets the rest)", plan.desired)
	}
}

func TestPlanPlacementSwitchesSurplusToDeficit(t *testing.T) {
	// 3 machines all on A; demand shifts to A:1 B:2. Two surplus A machines
	// should switch to B.
	models := []placementModel{{model: "A", need: 1}, {model: "B", need: 2}}
	old := placementNow.Add(-time.Hour) // past min-dwell
	machines := []placementMachine{
		{id: "m1", current: "A", assignedAt: old, idle: true, capable: capable("A", "B")},
		{id: "m2", current: "A", assignedAt: old, idle: true, capable: capable("A", "B")},
		{id: "m3", current: "A", assignedAt: old, idle: true, capable: capable("A", "B")},
	}
	plan := planPlacement(models, machines, 5*time.Minute, 10, placementNow)
	switched := 0
	for _, a := range plan.actions {
		if a.model == "B" {
			switched++
		}
	}
	if switched != 2 {
		t.Fatalf("expected 2 switches to B, got %d (%v)", switched, plan.actions)
	}
	if plan.current["A"] != 1 || plan.current["B"] != 2 {
		t.Fatalf("post-plan current=%v, want A:1 B:2", plan.current)
	}
}

func TestPlanPlacementRespectsMinDwell(t *testing.T) {
	// A machine assigned 1 minute ago must NOT be yanked under a 5-minute dwell,
	// even though it sits in a surplus pool.
	models := []placementModel{{model: "A", need: 0}, {model: "B", need: 1}}
	machines := []placementMachine{
		{id: "fresh", current: "A", assignedAt: placementNow.Add(-time.Minute), idle: true, capable: capable("A", "B")},
	}
	plan := planPlacement(models, machines, 5*time.Minute, 10, placementNow)
	if len(plan.actions) != 0 {
		t.Fatalf("min-dwell should block the switch, got %v", plan.actions)
	}
}

func TestPlanPlacementRespectsSwitchBudget(t *testing.T) {
	models := []placementModel{{model: "A", need: 0}, {model: "B", need: 3}}
	old := placementNow.Add(-time.Hour)
	machines := []placementMachine{
		{id: "m1", current: "A", assignedAt: old, idle: true, capable: capable("A", "B")},
		{id: "m2", current: "A", assignedAt: old, idle: true, capable: capable("A", "B")},
		{id: "m3", current: "A", assignedAt: old, idle: true, capable: capable("A", "B")},
	}
	plan := planPlacement(models, machines, 5*time.Minute, 1, placementNow) // budget 1
	if len(plan.actions) != 1 {
		t.Fatalf("switch budget=1 should cap at one switch, got %d", len(plan.actions))
	}
}

func TestPlanPlacementSkipsIncapableAndBusyMachines(t *testing.T) {
	models := []placementModel{{model: "B", need: 2}}
	old := placementNow.Add(-time.Hour)
	machines := []placementMachine{
		{id: "incapable", current: "", idle: true, capable: capable("A")},            // can't hold B
		{id: "busy", current: "", idle: false, capable: capable("B")},                // in-flight work
		{id: "ok", current: "A", assignedAt: old, idle: true, capable: capable("B")}, // surplus A, capable B
	}
	plan := planPlacement(models, machines, 5*time.Minute, 10, placementNow)
	got := actionMap(plan)
	if got["incapable"] != "" {
		t.Fatal("incapable machine must not be assigned B")
	}
	if got["busy"] != "" {
		t.Fatal("busy machine must not be switched")
	}
	if got["ok"] != "B" {
		t.Fatalf("the idle capable surplus machine should switch to B, got %v", plan.actions)
	}
}

func placementTestConfig(enforce bool) WarmPoolConfig {
	return WarmPoolConfig{
		Enabled:               true,
		PlacementEnabled:      true,
		PlacementEnforce:      enforce,
		MinDwell:              5 * time.Minute,
		MaxLoadsPerTick:       4,
		MaxGlobalPendingLoads: 16,
		ModelPriority:         map[string]int{"A": 10, "B": 1},
	}
}

func TestRunPlacementEnforcePushesAssignments(t *testing.T) {
	reg := New(testLogger())
	reg.ConfigureWarmPool(placementTestConfig(true))
	var pushed []string
	reg.assignModelSender = func(pid, mid string, _ uint64) error {
		pushed = append(pushed, mid)
		return nil
	}
	registerProviderWithModels(reg, "p1", "A", "B")
	registerProviderWithModels(reg, "p2", "A", "B")

	snaps := []WarmPoolSnapshot{{Model: "A", TargetWarm: 1}, {Model: "B", TargetWarm: 1}}
	reg.warmPool.runPlacement(placementNow, snaps)

	if len(pushed) != 2 {
		t.Fatalf("enforce: expected 2 assign_model pushes, got %v", pushed)
	}
	// Both pools should have been assigned exactly one machine.
	models := map[string]int{}
	for _, m := range pushed {
		models[m]++
	}
	if models["A"] != 1 || models["B"] != 1 {
		t.Fatalf("enforce: pushes should cover A:1 B:1, got %v", models)
	}
	// And the assignments are reflected in registry state.
	a1, _ := reg.ProviderAssignmentSnapshot("p1")
	a2, _ := reg.ProviderAssignmentSnapshot("p2")
	if a1.Model == "" || a2.Model == "" || a1.Model == a2.Model {
		t.Fatalf("expected the two machines split across pools, got %q / %q", a1.Model, a2.Model)
	}
}

func TestRunPlacementShadowDoesNotPush(t *testing.T) {
	reg := New(testLogger())
	reg.ConfigureWarmPool(placementTestConfig(false)) // PlacementEnforce=false → shadow
	pushed := 0
	reg.assignModelSender = func(string, string, uint64) error { pushed++; return nil }
	registerProviderWithModels(reg, "p1", "A", "B")

	reg.warmPool.runPlacement(placementNow, []WarmPoolSnapshot{{Model: "A", TargetWarm: 1}})
	if pushed != 0 {
		t.Fatalf("shadow mode must not push assignments, pushed=%d", pushed)
	}
	// But the plan is still computed + recorded for observability.
	snap, ok := reg.LatestPlacementSnapshot()
	if !ok || snap.Desired["A"] != 1 {
		t.Fatalf("shadow mode should record a plan with desired A:1, got %+v ok=%v", snap, ok)
	}
}

func TestRunPlacementSkipsUnmanageableProviders(t *testing.T) {
	reg := New(testLogger())
	reg.ConfigureWarmPool(placementTestConfig(true))
	reg.SetManageableProviderFunc(func(_, _ string) bool { return false }) // all too old
	pushed := 0
	reg.assignModelSender = func(string, string, uint64) error { pushed++; return nil }
	registerProviderWithModels(reg, "p1", "A", "B")

	reg.warmPool.runPlacement(placementNow, []WarmPoolSnapshot{{Model: "A", TargetWarm: 1}})
	if pushed != 0 {
		t.Fatalf("pre-feature providers must stay unmanaged (no push), pushed=%d", pushed)
	}
}

func TestPlanPlacementPrefersUnmanagedSource(t *testing.T) {
	// Both an unmanaged machine and a surplus-A machine can serve B; the
	// unmanaged one should be chosen first (don't disturb a serving pool).
	models := []placementModel{{model: "A", need: 1}, {model: "B", need: 1}}
	old := placementNow.Add(-time.Hour)
	machines := []placementMachine{
		{id: "surplusA", current: "A", assignedAt: old, idle: true, capable: capable("A", "B")},
		{id: "keepA", current: "A", assignedAt: old, idle: true, capable: capable("A", "B")},
		{id: "free", current: "", idle: true, capable: capable("A", "B")},
	}
	plan := planPlacement(models, machines, 5*time.Minute, 1, placementNow)
	got := actionMap(plan)
	if got["free"] != "B" {
		t.Fatalf("unmanaged machine should be the preferred source for B, got %v", plan.actions)
	}
}
