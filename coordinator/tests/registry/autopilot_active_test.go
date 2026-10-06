package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func autopilotActiveRequest(id, model string, now time.Time) *production.PendingRequest {
	root := production.NewRequestProfile(now.Add(-time.Second), id, nil, time.Second)
	root.HandlerEntryUS.Store(1)
	profile := root.NewAttempt(id, 0, "")
	profile.AcceptedUS.Store(1)
	return &production.PendingRequest{RequestID: id, Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 64,
		FirstContentDeadline: root.T0.Add(time.Microsecond + 30*time.Second), Profile: profile}
}

func TestAutopilotUnscopedWorkNeverCreatesPublicPlacementDemand(t *testing.T) {
	for _, scope := range []string{"local", "self", "prefer", "serial", "excluded", "cancelled", "completed", "missing profile", "missing start", "missing entry", "invalid"} {
		t.Run(scope, func(t *testing.T) {
			cfg := autopilot.DefaultConfig()
			cfg.Enabled, cfg.ObserveOnly = true, false
			cfg.AllowIdleUnload = false
			r, c, now := newAutopilotControllerTestConfig(t, cfg)
			warmCfg := testWarmPoolConfig()
			warmCfg.MinWarmByModel = nil
			r.ConfigureWarmPool(warmCfg)
			busy := autopilotControllerProvider(t, r, "busy", now, autopilotTestTarget)
			autopilotControllerProvider(t, r, "spare", now, autopilotTestDonor)
			busy.Mu().Lock()
			busy.BackendCapacity.Slots[0].NumRunning = 8
			busy.Mu().Unlock()
			for i := range 8 {
				p := autopilotActiveRequest(fmt.Sprint(i), autopilotTestTarget, now)
				switch scope {
				case "local":
					continue // not tracked by the public coordinator
				case "self":
					p.SelfRouteOnly = true
				case "prefer":
					p.PreferOwner = true
				case "serial":
					p.AllowedProviderSerials = []string{"restricted"}
				case "excluded":
					p.ExcludedProviderIDs = []string{"restricted"}
				case "cancelled":
					p.Profile.Parent().ClientGoneUS.Store(1)
				case "completed":
					p.Profile.ProviderCompleteObserved.Store(true)
				case "missing profile":
					p.Profile = nil
					p.FirstContentDeadline = time.Time{}
				case "missing start":
					p.Profile.Parent().T0 = time.Time{}
				case "missing entry":
					p.Profile.Parent().HandlerEntryUS.Store(0)
				case "invalid":
					p.EstimatedPromptTokens = 0
				}
				busy.AddPending(p)
			}
			f := c.Fleet(now)
			if len(f.Demand) != 0 {
				t.Fatalf("private/unqualified work entered public demand: %+v", f.Demand)
			}
			if action := autopilotcontrol.Plan(f, r.cfg, now); action != nil {
				t.Fatalf("private/unqualified work caused placement: %+v", action)
			}
			for _, node := range f.Nodes {
				if node.ID == busy.ID && (!node.UnscopedBusy || len(autopilot.NodeContribution(node, node.Residents, f.Demand)) != 0) {
					t.Fatal("unscoped busy device supplied spare public capacity")
				}
			}
		})
	}
}

func TestAutopilotPublicActiveTraitsAndQueueHandoffArePreserved(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.Enabled, cfg.ObserveOnly = true, false
	cfg.AllowIdleUnload = false
	// Exercise recipient eligibility with an explicit public-capacity deficit.
	cfg.TargetUtilization = .1
	r, c, now := newAutopilotControllerTestConfig(t, cfg)
	queue := production.NewRequestQueue(32, time.Minute)
	r.SetQueue(queue)
	warmCfg := testWarmPoolConfig()
	warmCfg.MinWarmByModel = nil
	r.ConfigureWarmPool(warmCfg)
	busy := autopilotControllerProvider(t, r, "busy", now, autopilotTestTarget)
	bad := autopilotControllerProvider(t, r, "a-ineligible", now, autopilotTestDonor)
	good := autopilotControllerProvider(t, r, "z-eligible", now, autopilotTestDonor)
	for _, p := range []*production.Provider{busy, bad, good} {
		p.Mu().Lock()
		p.Version = "0.9.10"
		p.Models[0].IsVision = true
		p.Models[0].NativeMediaTools = p != bad
		p.ToolConstraintProtocol = production.ToolConstraintProtocolV1
		p.ToolConstraintModels = map[string]struct{}{autopilotTestTarget: {}}
		p.Mu().Unlock()
	}
	busy.Mu().Lock()
	busy.BackendCapacity.Slots[0].NumRunning = 8
	busy.Mu().Unlock()
	for i := range 8 {
		p := autopilotActiveRequest(fmt.Sprint(i), autopilotTestTarget, now)
		p.RequiresVision = true
		p.Traits = production.RequestTraits{HasTools: true, RequiresNativeMediaTools: true}
		busy.AddPending(p)
		if i == 0 {
			if err := queue.Enqueue(&production.QueuedRequest{RequestID: p.RequestID, Model: p.Model, Pending: p}); err != nil {
				t.Fatal(err)
			}
		}
	}
	f := c.Fleet(now)
	a := autopilotcontrol.Plan(f, r.cfg, now)
	if a == nil || a.Node.ID != good.ID {
		t.Fatalf("active trait gates bypassed: %+v fleet=%+v coverage=%+v", a, f.Fleet, autopilot.Coverage(f.Fleet))
	}
	for _, d := range f.Demand {
		if d.InFlight != 8 || d.Queued != 0 || d.Requests != 0 || !d.RequiresNativeMediaTools || d.DeadlineSeconds != 30 {
			t.Fatalf("active/queue handoff duplicated work or lost eligibility: %+v", d)
		}
	}
}
