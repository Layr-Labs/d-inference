package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotQueueExcludesRestrictedCancelledAndExpiredWork(t *testing.T) {
	q := NewRequestQueue(32, time.Minute)
	now := time.Now()
	for _, kind := range []string{"public", "self", "prefer", "serial", "excluded", "nil", "cancelled", "profile cancelled", "stale", "deadline"} {
		p := &PendingRequest{Model: autopilotTestTarget, EstimatedPromptTokens: 100, RequestedMaxTokens: 64,
			RequiresVision: true, Traits: RequestTraits{HasTools: true, RequiresNativeMediaTools: true, ToolChoiceMode: "none", MinPrefixCacheProtocol: 1},
			FirstContentDeadline: now.Add(30 * time.Second)}
		switch kind {
		case "self":
			p.SelfRouteOnly = true
		case "prefer":
			p.PreferOwner = true
		case "serial":
			p.AllowedProviderSerials = []string{"private"}
		case "excluded":
			p.ExcludedProviderIDs = []string{"restricted"}
		case "nil":
			p = nil
		case "profile cancelled":
			p.Profile = autopilotActiveRequest("cancelled", p.Model, now).Profile
			p.Profile.Parent().ClientGoneUS.Store(1)
		case "deadline":
			p.FirstContentDeadline = now.Add(-time.Second)
		}
		queued := &QueuedRequest{RequestID: kind, Model: autopilotTestTarget, Pending: p}
		if err := q.Enqueue(queued); err != nil {
			t.Fatal(err)
		}
		if kind == "cancelled" {
			queued.markDone()
		}
		if kind == "stale" {
			queued.EnqueuedAt = now.Add(-2 * time.Minute)
		}
	}
	samples := q.autopilotSamples(now, nil)
	if len(samples) != 1 {
		t.Fatalf("qualified queue count=%d", len(samples))
	}
	sample := samples[0]
	if !sample.RequiresVision || !sample.RequiresNativeMediaTools || sample.ToolChoiceMode != "none" ||
		sample.MinPrefixCacheProtocol != 1 || sample.FirstContentDeadline != 30*time.Second {
		t.Fatalf("lost queued requirements: %+v", sample)
	}
}

func TestAutopilotQueuedNativeToolsCannotCreditIneligibleProvider(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	r.queue = NewRequestQueue(32, time.Minute)
	for _, id := range []string{"a-ineligible", "z-eligible"} {
		p := autopilotControllerProvider(t, r, id, now)
		p.mu.Lock()
		p.Version = "0.9.10"
		p.Models[0].IsVision = true
		p.Models[0].NativeMediaTools = id == "z-eligible"
		p.ToolConstraintProtocol = ToolConstraintProtocolV1
		p.ToolConstraintModels = map[string]struct{}{autopilotTestTarget: {}}
		p.syncModelIndexLocked()
		p.mu.Unlock()
	}
	p := &PendingRequest{Model: autopilotTestTarget, EstimatedPromptTokens: 100, RequestedMaxTokens: 64,
		RequiresVision: true, Traits: RequestTraits{HasTools: true, RequiresNativeMediaTools: true}}
	if err := r.queue.Enqueue(&QueuedRequest{RequestID: "queued", Model: p.Model, Pending: p}); err != nil {
		t.Fatal(err)
	}
	f := r.autopilotFleetSnapshot(c, now)
	a := planAutopilotAction(f, c.config, now)
	if a == nil || a.Node.ID != "z-eligible" {
		t.Fatalf("queued eligibility bypassed: action=%+v fleet=%+v coverage=%+v", a, f.Fleet, autopilot.Coverage(f.Fleet))
	}
	for key, d := range f.Demand {
		if autopilot.ShapeLabel(key) == "" || d.Queued != 1 || d.Requests != 0 {
			t.Fatalf("unshaped or fabricated demand: %q %+v", key, d)
		}
	}
	if len(c.demand.ShapeSnapshot(now, c.config.DemandWindow)) != 0 {
		t.Fatal("queue snapshot counted a logical terminal")
	}
	r.queue.Remove("queued", p.Model)
	if len(r.autopilotFleetSnapshot(c, now).Demand) != 0 {
		t.Fatal("removed queue pressure survived")
	}
}
