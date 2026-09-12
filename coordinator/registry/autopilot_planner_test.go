package registry

import (
	"math"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func autopilotPlannerFloat(v float64) *float64 { return &v }

func autopilotPlannerFit(rate, service float64) autopilotModelFit {
	return autopilotModelFit{Rate: rate, ServiceSeconds: service, LoadSeconds: 10, WeightsGiB: 8, Measured: true, MeetsDeadline: true}
}

func autopilotPlannerNode(id string, residents ...string) autopilotNode {
	n := autopilotNode{
		ID: id, Managed: true, Idle: true, Residents: append([]string(nil), residents...), Fits: map[string]autopilotModelFit{},
		State: &protocol.ModelAutopilotState{
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
		f := autopilotFleet{Nodes: []autopilotNode{slow, fast}, Demand: map[string]autopilotDemandView{
			"target": {Rate: rate, Requests: 10, ServiceSeconds: 10},
		}}
		a := planAutopilotAction(f, DefaultAutopilotConfig(), autopilotDemandTestClock())
		if a == nil || a.Node.ID != fast.ID || a.Load != "target" {
			t.Fatalf("recipient-specific service cancelled speed advantage at rate %g: %+v", rate, a)
		}
		if a.Future["target"] != .7 {
			t.Fatalf("wrong future service capacity: %+v", a)
		}
	}
}

func TestAutopilotPlannerUnqualifiedResidentCannotHideDeficit(t *testing.T) {
	bad, good := autopilotPlannerNode("bad", "target"), autopilotPlannerNode("good")
	badFit := autopilotPlannerFit(100, .01)
	badFit.MeetsDeadline = false
	bad.Fits["target"] = badFit
	good.Fits["target"] = autopilotPlannerFit(.7, 1)
	f := autopilotFleet{Nodes: []autopilotNode{bad, good}, Demand: map[string]autopilotDemandView{
		"target": {Rate: 2, Requests: 20, ServiceSeconds: 10},
	}, Floors: map[string]int{"target": 1}}
	c := autopilotCoverage(f)
	if c.Ready["target"] != 0 || c.Warm["target"] != 0 || len(bad.Residents) != 1 {
		t.Fatalf("deadline-infeasible residency got useful credit or lost ownership: %+v", c)
	}
	a := planAutopilotAction(f, DefaultAutopilotConfig(), autopilotDemandTestClock())
	if a == nil || a.Node.ID != good.ID {
		t.Fatalf("bad residents hid a useful recipient: %+v", a)
	}
	// Even an existing deficit must not debit a contribution never credited.
	if !autopilotDonorsProtected(f, c, bad) {
		t.Fatal("uncounted resident caused a fictitious negative floor/capacity")
	}
}

func TestAutopilotPlannerSharedGPUDoesNotSumIndependentThroughputs(t *testing.T) {
	n := autopilotPlannerNode("shared", "a", "b")
	n.Fits["a"], n.Fits["b"] = autopilotPlannerFit(2, 1), autopilotPlannerFit(4, .5)
	d := map[string]autopilotDemandView{"a": {Rate: 1}, "b": {Rate: 1}}
	contribution := autopilotNodeContribution(n, n.Residents, d)
	if math.Abs(contribution["a"]-4.0/3) > 1e-12 || math.Abs(contribution["b"]-4.0/3) > 1e-12 {
		t.Fatalf("wrong GPU time allocation: %+v", contribution)
	}
	if got := contribution["a"]/2 + contribution["b"]/4; math.Abs(got-1) > 1e-12 {
		t.Fatalf("shared GPU credited %g machines", got)
	}
	bad := n.Fits["b"]
	bad.MeetsDeadline = false
	n.Fits["b"] = bad
	contribution = autopilotNodeContribution(n, n.Residents, d)
	if _, exists := contribution["b"]; exists || math.Abs(contribution["a"]-4.0/3) > 1e-12 {
		t.Fatalf("unqualified work got useful credit or its contention vanished: %+v", contribution)
	}
}

func TestAutopilotPlannerOccupancyIsMaximumAndIncludesNewModels(t *testing.T) {
	n := autopilotPlannerNode("new-capacity")
	n.Fits["new"] = autopilotPlannerFit(.7, 10)
	f := autopilotFleet{Nodes: []autopilotNode{n}, Occupancy: map[string]int{"new": 20}}
	c := autopilotCoverage(f)
	if c.Need["new"] != 2 || c.Workload["new"].Rate != 2 {
		t.Fatalf("unfinished requests disappeared before first terminal: %+v", c)
	}
	if a := planAutopilotAction(f, DefaultAutopilotConfig(), autopilotDemandTestClock()); a == nil || a.Load != "new" {
		t.Fatalf("occupancy-only model was omitted from planning: %+v", a)
	}
	f.Demand = map[string]autopilotDemandView{"new": {Rate: 1, ServiceSeconds: 10}}
	if got := autopilotCoverage(f).Need["new"]; got != 2 {
		t.Fatalf("overlapping workload was added twice: %g", got)
	}
	f.Demand["new"] = autopilotDemandView{Rate: 3, ServiceSeconds: 10}
	if got := autopilotCoverage(f).Need["new"]; got != 3 {
		t.Fatalf("max lost the larger offered rate: %g", got)
	}
}

func autopilotPlannerDonorFixture() (autopilotFleet, autopilotNode) {
	donor := autopilotPlannerNode("donor", "a", "b")
	donor.State.FreeForLoadNoEvictGB = autopilotPlannerFloat(0)
	donor.State.MaxModelSlots = 2
	donor.Fits["target"] = autopilotPlannerFit(1, 1)
	peerA := autopilotPlannerNode("peer-a", "a")
	peerA.Managed = false
	f := autopilotFleet{Nodes: []autopilotNode{donor, peerA}, Demand: map[string]autopilotDemandView{
		"a":      {Rate: .2, Requests: 10, ServiceSeconds: 1},
		"b":      {Rate: .2, Requests: 10, ServiceSeconds: 1},
		"target": {Rate: 2, Requests: 10, ServiceSeconds: 10},
	}}
	return f, donor
}

func TestAutopilotPlannerProtectsEveryDonorOnSharedDevice(t *testing.T) {
	f, donor := autopilotPlannerDonorFixture()
	if autopilotDonorsProtected(f, autopilotCoverage(f), donor) {
		t.Fatal("first protected victim masked the second model's deficit")
	}
	if a := planAutopilotAction(f, DefaultAutopilotConfig(), autopilotDemandTestClock()); a != nil {
		t.Fatalf("unsafe multi-victim plan: %+v", a)
	}
	peerB := autopilotPlannerNode("peer-b", "b")
	peerB.Managed = false
	f.Nodes = append(f.Nodes, peerB)
	a := planAutopilotAction(f, DefaultAutopilotConfig(), autopilotDemandTestClock())
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
	c := autopilotCoverage(f)
	if c.Future["b"] != 100 || c.Warm["b"] != 1 || c.Ready["b"] != .5 {
		t.Fatalf("pending residency leaked ready credit: %+v", c)
	}
	if autopilotDonorsProtected(f, c, donor) {
		t.Fatal("future load protected a currently needed donor")
	}
}

func TestAutopilotPlannerVictimsRespectPinsDwellAndActualReclaim(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*autopilotNode)
		want   bool
	}{
		{"actual reclaim", func(*autopilotNode) {}, true},
		{"pinned", func(n *autopilotNode) { n.State.PinnedModels = []string{"a"} }, false},
		{"young resident", func(n *autopilotNode) { n.State.ResidentModels[0].ResidentSeconds = 1 }, false},
		{"recent work", func(n *autopilotNode) { n.State.ResidentModels[0].IdleSeconds = 1 }, false},
		{"provider longer dwell", func(n *autopilotNode) { n.State.MinDwellSeconds = 8000 }, false},
		{"padded weights are not reclaim", func(n *autopilotNode) {
			for i := range n.State.ResidentModels {
				n.State.ResidentModels[i].ResidentGB = nil
			}
		}, false},
		{"negative reclaim", func(n *autopilotNode) { n.State.ResidentModels[0].ResidentGB = autopilotPlannerFloat(-10) }, false},
		{"invalid free memory", func(n *autopilotNode) { n.State.FreeForLoadNoEvictGB = autopilotPlannerFloat(math.NaN()) }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, n := autopilotPlannerDonorFixture()
			tc.change(&n)
			victims, ok := autopilotVictims(n, "target", DefaultAutopilotConfig())
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
	victims, ok := autopilotVictims(n, "target", DefaultAutopilotConfig())
	if !ok || len(victims) != 0 {
		t.Fatalf("unnecessary eviction: %v allowed=%v", victims, ok)
	}
}

func TestAutopilotPlannerStandaloneUnloadRequiresEveryGuard(t *testing.T) {
	now := autopilotDemandTestClock()
	for _, tc := range []struct {
		name   string
		change func(*autopilotFleet, *AutopilotConfig)
		want   bool
	}{
		{"idle surplus under pressure", func(*autopilotFleet, *AutopilotConfig) {}, true},
		{"default disabled", func(_ *autopilotFleet, c *AutopilotConfig) { c.AllowIdleUnload = false }, false},
		{"not opted in", func(f *autopilotFleet, _ *AutopilotConfig) { f.Nodes[0].Managed = false }, false},
		{"busy", func(f *autopilotFleet, _ *AutopilotConfig) { f.Nodes[0].Idle = false }, false},
		{"pending", func(f *autopilotFleet, _ *AutopilotConfig) { f.Nodes[0].Pending = true }, false},
		{"no memory pressure", func(f *autopilotFleet, _ *AutopilotConfig) { f.Nodes[0].MemoryPressure = .2 }, false},
		{"unknown state", func(f *autopilotFleet, _ *AutopilotConfig) { f.Nodes[0].State = nil }, false},
		{"pinned", func(f *autopilotFleet, _ *AutopilotConfig) { f.Nodes[0].State.PinnedModels = []string{"a"} }, false},
		{"floor", func(f *autopilotFleet, _ *AutopilotConfig) { f.Floors = map[string]int{"a": 1} }, false},
		{"recent arrival", func(f *autopilotFleet, _ *AutopilotConfig) {
			f.Demand["a"] = autopilotDemandView{LastDemand: now.Add(-time.Minute)}
		}, false},
		{"young residency", func(f *autopilotFleet, _ *AutopilotConfig) { f.Nodes[0].State.ResidentModels[0].ResidentSeconds = 1 }, false},
		{"recent device work", func(f *autopilotFleet, _ *AutopilotConfig) { f.Nodes[0].State.ResidentModels[0].IdleSeconds = 1 }, false},
		{"provider longer idle dwell", func(f *autopilotFleet, _ *AutopilotConfig) {
			f.Nodes[0].State.MinDwellSeconds = 7200
			f.Nodes[0].State.ResidentModels[0].ResidentSeconds = 10800
			f.Nodes[0].State.ResidentModels[0].IdleSeconds = 3600
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			n := autopilotPlannerNode("idle", "a")
			n.MemoryPressure = .9
			f := autopilotFleet{Nodes: []autopilotNode{n}, Demand: map[string]autopilotDemandView{}}
			cfg := DefaultAutopilotConfig()
			cfg.AllowIdleUnload = true
			tc.change(&f, &cfg)
			a := planAutopilotAction(f, cfg, now)
			if (a != nil) != tc.want || (a != nil && (a.Load != "" || !slices.Equal(a.Unload, []string{"a"}))) {
				t.Fatalf("standalone unload=%+v, want allowed=%v", a, tc.want)
			}
		})
	}
}
