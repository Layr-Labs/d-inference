package autopilot_test

import (
	"math"
	"reflect"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/residency"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry/autopilot"

	"slices"

	"time"
)

func autopilotPlannerFloat(v float64) *float64 { return &v }

func autopilotPlannerFit(rate, service float64) production.ModelFit {
	return production.ModelFit{Rate: rate, ServiceSeconds: service, LoadSeconds: 10, WeightsGiB: 8, Measured: true, MeetsDeadline: true}
}

func autopilotPlannerNode(id string, residents ...string) production.Node {
	n := production.Node{
		ID: id, Managed: true, Idle: true, Residents: append([]string(nil), residents...), Fits: map[string]production.ModelFit{},
		State: &protocol.ModelAutopilotState{MinIdleSeconds: 1800,
			Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true,
			MaxModelSlots: 3, FreeForLoadNoEvictGB: autopilotPlannerFloat(32),
		},
	}
	for _, m := range residents {
		n.Fits[m] = autopilotPlannerFit(1, 1)
		n.State.ResidentModels = append(n.State.ResidentModels, protocol.ModelAutopilotResident{
			ModelID: m, ResidentSeconds: 7200, IdleSeconds: 7200, WeightsGB: 100, ResidentGB: autopilotPlannerFloat(5),
		})
	}
	return n
}

func TestAutopilotPlannerPrefersQualifiedFastRecipient(t *testing.T) {
	slow, fast := autopilotPlannerNode("a-slow"), autopilotPlannerNode("z-fast")
	slow.Fits["target"] = autopilotPlannerFit(.07, 10)
	fast.Fits["target"] = autopilotPlannerFit(.7, 1)
	for _, rate := range []float64{.2, 2} {
		f := production.Fleet{Nodes: []production.Node{slow, fast}, Demand: map[string]production.DemandView{
			"target": {Rate: rate, Requests: 10, ServiceSeconds: 10},
		}}
		a := production.Plan(f, production.DefaultConfig(), autopilotDemandTestClock())
		if a == nil || a.Node.ID != fast.ID || a.Load != "target" {
			t.Fatalf("recipient-specific service cancelled speed advantage at rate %g: %+v", rate, a)
		}
		if a.Future["target"] != .7 {
			t.Fatalf("wrong future service capacity: %+v", a)
		}
	}
}

func TestAutopilotPlannerSharedGPUDoesNotSumIndependentThroughputs(t *testing.T) {
	n := autopilotPlannerNode("shared", "a", "b")
	n.Fits["a"], n.Fits["b"] = autopilotPlannerFit(2, 1), autopilotPlannerFit(4, .5)
	d := map[string]production.DemandView{"a": {Rate: 1}, "b": {Rate: 1}}
	contribution := production.NodeContribution(n, n.Residents, d)
	if math.Abs(contribution["a"]-4.0/3) > 1e-12 || math.Abs(contribution["b"]-4.0/3) > 1e-12 {
		t.Fatalf("wrong GPU time allocation: %+v", contribution)
	}
	if got := contribution["a"]/2 + contribution["b"]/4; math.Abs(got-1) > 1e-12 {
		t.Fatalf("shared GPU credited %g machines", got)
	}
	bad := n.Fits["b"]
	bad.MeetsDeadline = false
	n.Fits["b"] = bad
	contribution = production.NodeContribution(n, n.Residents, d)
	if _, exists := contribution["b"]; exists || math.Abs(contribution["a"]-4.0/3) > 1e-12 {
		t.Fatalf("unqualified work got useful credit or its contention vanished: %+v", contribution)
	}
}

func TestAutopilotPlannerPublicInflightIsMaximumAndIncludesNewModels(t *testing.T) {
	n := autopilotPlannerNode("new-capacity")
	n.Fits["new"] = autopilotPlannerFit(.7, 10)
	f := production.Fleet{Nodes: []production.Node{n}, Demand: map[string]production.DemandView{"new": {InFlight: 20, ServiceSeconds: 10}}}
	c := production.Coverage(f)
	if c.Need["new"] != 2 || c.Workload["new"].Rate != 2 {
		t.Fatalf("unfinished requests disappeared before first terminal: %+v", c)
	}
	if a := production.Plan(f, production.DefaultConfig(), autopilotDemandTestClock()); a == nil || a.Load != "new" {
		t.Fatalf("occupancy-only model was omitted from planning: %+v", a)
	}
	f.Demand = map[string]production.DemandView{"new": {Rate: 1, InFlight: 20, ServiceSeconds: 10}}
	if got := production.Coverage(f).Need["new"]; got != 2 {
		t.Fatalf("overlapping workload was added twice: %g", got)
	}
	f.Demand["new"] = production.DemandView{Rate: 3, InFlight: 20, ServiceSeconds: 10}
	if got := production.Coverage(f).Need["new"]; got != 3 {
		t.Fatalf("max lost the larger offered rate: %g", got)
	}
}

func TestAutopilotPlannerStandaloneUnloadRequiresEveryGuard(t *testing.T) {
	now := autopilotDemandTestClock()
	for _, tc := range []struct {
		name   string
		change func(*production.Fleet, *production.Config)
		want   bool
	}{
		{"idle surplus under pressure", func(*production.Fleet, *production.Config) {}, true},
		{"default disabled", func(_ *production.Fleet, c *production.Config) { c.AllowIdleUnload = false }, false},
		{"not opted in", func(f *production.Fleet, _ *production.Config) { f.Nodes[0].Managed = false }, false},
		{"busy", func(f *production.Fleet, _ *production.Config) { f.Nodes[0].Idle = false }, false},
		{"pending", func(f *production.Fleet, _ *production.Config) { f.Nodes[0].Pending = true }, false},
		{"no memory pressure needed", func(f *production.Fleet, _ *production.Config) { f.Nodes[0].MemoryPressure = .2 }, true},
		{"unknown state", func(f *production.Fleet, _ *production.Config) { f.Nodes[0].State = nil }, false},
		{"pinned", func(f *production.Fleet, _ *production.Config) { f.Nodes[0].State.PinnedModels = []string{"a"} }, false},
		{"floor", func(f *production.Fleet, _ *production.Config) { f.Floors = map[string]int{"a": 1} }, false},
		{"recent arrival", func(f *production.Fleet, _ *production.Config) {
			f.Demand["a"] = production.DemandView{LastDemand: now.Add(-time.Minute)}
		}, false},
		{"young residency", func(f *production.Fleet, _ *production.Config) {
			f.Nodes[0].State.ResidentModels[0].ResidentSeconds = 1
		}, false},
		{"recent device work", func(f *production.Fleet, _ *production.Config) { f.Nodes[0].State.ResidentModels[0].IdleSeconds = 1 }, false},
		{"provider longer idle dwell", func(f *production.Fleet, _ *production.Config) {
			f.Nodes[0].State.MinIdleSeconds = 7200
			f.Nodes[0].State.ResidentModels[0].ResidentSeconds = 10800
			f.Nodes[0].State.ResidentModels[0].IdleSeconds = 3600
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			n := autopilotPlannerNode("idle", "a")
			n.MemoryPressure = .9
			f := production.Fleet{Nodes: []production.Node{n}, Demand: map[string]production.DemandView{}}
			cfg := production.DefaultConfig()
			cfg.AllowIdleUnload = true
			tc.change(&f, &cfg)
			a := production.Plan(f, cfg, now)
			if (a != nil) != tc.want || (a != nil && (a.Load != "" || !slices.Equal(a.Unload, []string{"a"}))) {
				t.Fatalf("standalone unload=%+v, want allowed=%v", a, tc.want)
			}
		})
	}
}

func TestAutopilotPlannerUnqualifiedResidentCannotHideDeficit(t *testing.T) {
	bad, good := autopilotPlannerNode("bad", "target"), autopilotPlannerNode("good")
	badFit := autopilotPlannerFit(100, .01)
	badFit.MeetsDeadline = false
	bad.Fits["target"] = badFit
	good.Fits["target"] = autopilotPlannerFit(.7, 1)
	f := production.Fleet{Nodes: []production.Node{bad, good}, Demand: map[string]production.DemandView{
		"target": {Rate: 2, Requests: 20, ServiceSeconds: 10},
	}, Floors: map[string]int{"target": 1}}
	c := production.Coverage(f)
	if c.Ready["target"] != 0 || c.Warm["target"] != 0 || len(bad.Residents) != 1 {
		t.Fatalf("deadline-infeasible residency got useful credit or lost ownership: %+v", c)
	}
	a := production.Plan(f, production.DefaultConfig(), autopilotDemandTestClock())
	if a == nil || a.Node.ID != good.ID {
		t.Fatalf("bad residents hid a useful recipient: %+v", a)
	}
	// Even an existing deficit must not debit a contribution never credited.
	if !plannerDonorsProtected(f, c, bad) {
		t.Fatal("uncounted resident caused a fictitious negative floor/capacity")
	}
}

func autopilotPlannerDonorFixture() (production.Fleet, production.Node) {
	donor := autopilotPlannerNode("donor", "a", "b")
	donor.State.FreeForLoadNoEvictGB = autopilotPlannerFloat(0)
	donor.State.MaxModelSlots = 2
	donor.Fits["target"] = autopilotPlannerFit(1, 1)
	peerA := autopilotPlannerNode("peer-a", "a")
	peerA.Managed = false
	f := production.Fleet{Nodes: []production.Node{donor, peerA}, Demand: map[string]production.DemandView{
		"a":      {Rate: .2, Requests: 10, ServiceSeconds: 1},
		"b":      {Rate: .2, Requests: 10, ServiceSeconds: 1},
		"target": {Rate: 2, Requests: 10, ServiceSeconds: 10},
	}}
	return f, donor
}

func TestAutopilotPlannerProtectsEveryDonorOnSharedDevice(t *testing.T) {
	f, donor := autopilotPlannerDonorFixture()
	if plannerDonorsProtected(f, production.Coverage(f), donor) {
		t.Fatal("first protected victim masked the second model's deficit")
	}
	if a := production.Plan(f, production.DefaultConfig(), autopilotDemandTestClock()); a != nil {
		t.Fatalf("unsafe multi-victim plan: %+v", a)
	}
	peerB := autopilotPlannerNode("peer-b", "b")
	peerB.Managed = false
	f.Nodes = append(f.Nodes, peerB)
	a := production.Plan(f, production.DefaultConfig(), autopilotDemandTestClock())
	if a == nil || a.Node.ID != donor.ID || !reflect.DeepEqual(a.Unload, []string{"a", "b"}) {
		t.Fatalf("protected feasible multi-victim move missing: %+v", a)
	}
}

func TestAutopilotPlannerPendingCapacityCannotProtectDonors(t *testing.T) {
	f, donor := autopilotPlannerDonorFixture()
	pending := autopilotPlannerNode("pending-b", "b")
	pending.Pending = true
	pending.Future = map[string]float64{"b": 100}
	f.Nodes = append(f.Nodes, pending)
	c := production.Coverage(f)
	if c.Future["b"] != 100 || c.Warm["b"] != 1 || c.Ready["b"] != .5 {
		t.Fatalf("pending residency leaked ready credit: %+v", c)
	}
	if plannerDonorsProtected(f, c, donor) {
		t.Fatal("future load protected a currently needed donor")
	}
}

func TestAutopilotPlannerVictimsRespectPinsDwellAndActualReclaim(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*production.Node)
		want   bool
	}{
		{"actual reclaim", func(*production.Node) {}, true},
		{"pinned", func(n *production.Node) { n.State.PinnedModels = []string{"a"} }, false},
		{"young resident", func(n *production.Node) { n.State.ResidentModels[0].ResidentSeconds = 1 }, false},
		{"recent work", func(n *production.Node) { n.State.ResidentModels[0].IdleSeconds = 1 }, false},
		{"provider longer dwell", func(n *production.Node) { n.State.MinDwellSeconds = 8000 }, false},
		{"padded weights are not reclaim", func(n *production.Node) {
			for i := range n.State.ResidentModels {
				n.State.ResidentModels[i].ResidentGB = nil
			}
		}, false},
		{"negative reclaim", func(n *production.Node) { n.State.ResidentModels[0].ResidentGB = autopilotPlannerFloat(-10) }, false},
		{"invalid free memory", func(n *production.Node) { n.State.FreeForLoadNoEvictGB = autopilotPlannerFloat(math.NaN()) }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, n := autopilotPlannerDonorFixture()
			tc.change(&n)
			victims, ok := residency.SelectVictims(n.State, n.Residents, n.Fits["target"].WeightsGiB, production.DefaultConfig().MinDwell)
			if ok != tc.want || (ok && !reflect.DeepEqual(victims, []string{"a", "b"})) {
				t.Fatalf("victims=%v allowed=%v, want %v", victims, ok, tc.want)
			}
		})
	}
}

func TestAutopilotPlannerNoEvictionWhenSlotAndMemoryAlreadyFit(t *testing.T) {
	n := autopilotPlannerNode("room", "a")
	n.State.PinnedModels = []string{"a"}
	n.Fits["target"] = autopilotPlannerFit(1, 1)
	victims, ok := residency.SelectVictims(n.State, n.Residents, n.Fits["target"].WeightsGiB, production.DefaultConfig().MinDwell)
	if !ok || len(victims) != 0 {
		t.Fatalf("unnecessary eviction: %v allowed=%v", victims, ok)
	}
}

// These fixtures use one exact model-level workload per model. Retain Coverage's
// actual contribution and the real residency policies when constructing debits.
func plannerDonorsProtected(f production.Fleet, c production.CoverageView, n production.Node) bool {
	var budgets []residency.ResidentBudget
	for _, model := range n.Residents {
		d := f.Demand[model]
		budgets = append(budgets, residency.ResidentBudget{
			Qualified: residency.QualifiedResident(n.Fits, model), Warm: c.Warm[model],
			Floor: residency.ProtectedFloor(f.Floors[model], d.Rate, d.Requests, d.CapacityShed),
		})
	}
	return residency.ProtectsDonors(budgets, c.Contribution[n.ID], c.Ready, c.Need)
}
