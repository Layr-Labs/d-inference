package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func autopilotActiveRequest(id, model string, now time.Time) *PendingRequest {
	root := NewRequestProfile(now.Add(-time.Second), id, nil, time.Second)
	root.HandlerEntryUS.Store(1)
	profile := root.NewAttempt(id, 0, "")
	profile.AcceptedUS.Store(1)
	return &PendingRequest{RequestID: id, Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 64,
		FirstContentDeadline: root.T0.Add(time.Microsecond + 30*time.Second), Profile: profile}
}

func TestAutopilotUnscopedWorkNeverCreatesPublicPlacementDemand(t *testing.T) {
	for _, scope := range []string{"local", "self", "prefer", "serial", "excluded", "cancelled", "completed", "missing profile", "missing start", "missing entry", "invalid"} {
		t.Run(scope, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			r.warmPool.config.MinWarmByModel = nil
			c.config.AllowIdleUnload = false
			busy := autopilotControllerProvider(t, r, "busy", now, autopilotTestTarget)
			autopilotControllerProvider(t, r, "spare", now, autopilotTestDonor)
			busy.mu.Lock()
			busy.BackendCapacity.Slots[0].NumRunning = 8
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
				busy.pendingReqs[p.RequestID] = p
			}
			busy.mu.Unlock()
			f := r.autopilotFleetSnapshot(c, now)
			if len(f.Demand) != 0 {
				t.Fatalf("private/unqualified work entered public demand: %+v", f.Demand)
			}
			if action := planAutopilotAction(f, c.config, now); action != nil {
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
	r, c, now := newAutopilotControllerTest(t, false)
	r.queue = NewRequestQueue(32, time.Minute)
	r.warmPool.config.MinWarmByModel = nil
	c.config.AllowIdleUnload = false
	// Exercise recipient eligibility with an explicit public-capacity deficit.
	c.config.TargetUtilization = .1
	busy := autopilotControllerProvider(t, r, "busy", now, autopilotTestTarget)
	bad := autopilotControllerProvider(t, r, "a-ineligible", now, autopilotTestDonor)
	good := autopilotControllerProvider(t, r, "z-eligible", now, autopilotTestDonor)
	for _, p := range []*Provider{busy, bad, good} {
		p.mu.Lock()
		p.Version = "0.9.10"
		p.Models[0].IsVision = true
		p.Models[0].NativeMediaTools = p != bad
		p.ToolConstraintProtocol = ToolConstraintProtocolV1
		p.ToolConstraintModels = map[string]struct{}{autopilotTestTarget: {}}
		p.syncModelIndexLocked()
		p.mu.Unlock()
	}
	busy.mu.Lock()
	busy.BackendCapacity.Slots[0].NumRunning = 8
	for i := range 8 {
		p := autopilotActiveRequest(fmt.Sprint(i), autopilotTestTarget, now)
		p.RequiresVision = true
		p.Traits = RequestTraits{HasTools: true, RequiresNativeMediaTools: true}
		busy.pendingReqs[p.RequestID] = p
		if i == 0 {
			if err := r.queue.Enqueue(&QueuedRequest{RequestID: p.RequestID, Model: p.Model, Pending: p}); err != nil {
				t.Fatal(err)
			}
		}
	}
	busy.mu.Unlock()
	f := r.autopilotFleetSnapshot(c, now)
	a := planAutopilotAction(f, c.config, now)
	if a == nil || a.Node.ID != good.ID {
		t.Fatalf("active trait gates bypassed: %+v fleet=%+v coverage=%+v", a, f.Fleet, autopilot.Coverage(f.Fleet))
	}
	for _, d := range f.Demand {
		if d.InFlight != 8 || d.Queued != 0 || d.Requests != 0 || !d.RequiresNativeMediaTools || d.DeadlineSeconds != 30 {
			t.Fatalf("active/queue handoff duplicated work or lost eligibility: %+v", d)
		}
	}
}
