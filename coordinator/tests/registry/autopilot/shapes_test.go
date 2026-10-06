package autopilot_test

import (
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotShapesKeepOrdinaryRequestsIndependent(t *testing.T) {
	d := production.DemandTracker{}
	now := time.Now()
	ordinary := production.DemandSample{Model: "mixed", ReceivedAt: now.Add(-time.Second), PromptTokens: 100, RequestedMaxTokens: 128}
	special := ordinary
	special.RequiresVision = true
	special.HasTools = true
	special.PromptTokens = 32000
	for range 20 {
		d.Record(ordinary, now, 5*time.Minute)
	}
	d.Record(special, now, 5*time.Minute)
	shapes := d.ShapeSnapshot(now, 5*time.Minute)
	if len(shapes) != 2 {
		t.Fatalf("cohorts=%+v", shapes)
	}
	a, b := shapes[production.ShapeKey(ordinary)], shapes[production.ShapeKey(special)]
	if a.RequiresVision || a.HasTools || a.Requests != 20 || !b.RequiresVision || b.Requests != 1 {
		t.Fatalf("shape requirements leaked: %+v", shapes)
	}
	node := production.Node{ID: "plain", Residents: []string{"mixed"}}
	node.Fits = map[string]production.ModelFit{production.ShapeKey(ordinary): production.ModelFit{Rate: 10, ServiceSeconds: 1, MeetsDeadline: true}}
	capacity := production.NodeContribution(node, node.Residents, shapes)
	if capacity[production.ShapeKey(ordinary)] <= 0 || capacity[production.ShapeKey(special)] != 0 {
		t.Fatalf("capacity=%+v", capacity)
	}
}

func TestAutopilotCohortsRetainEveryHardRequirementAcrossBuckets(t *testing.T) {
	now := time.Now()
	tracker := production.DemandTracker{}
	var samples []production.DemandSample
	for flags := 0; flags < 16; flags++ {
		for _, mode := range []string{"", "auto", "none", "required", "named"} {
			for prefix := 0; prefix < 2; prefix++ {
				sample := production.DemandSample{Model: "same-build", PromptTokens: 100, RequestedMaxTokens: 64,
					Requirements: production.Requirements{RequiresVision: flags&1 != 0, HasTools: flags&2 != 0,
						RequiresToolConstraint: flags&4 != 0, RequiresNativeMediaTools: flags&8 != 0,
						ToolChoiceMode: mode, MinPrefixCacheProtocol: prefix}}
				for _, age := range []time.Duration{time.Second, 21 * time.Second} {
					sample.ReceivedAt = now.Add(-age)
					tracker.Record(sample, now, time.Minute)
				}
				samples = append(samples, sample)
			}
		}
	}
	views := tracker.ShapeSnapshot(now, time.Minute)
	if len(views) != len(samples) {
		t.Fatalf("cohorts=%d want=%d", len(views), len(samples))
	}
	for _, sample := range samples {
		view := views[production.ShapeKey(sample)]
		if view.Requirements != sample.Requirements || view.Requests != 2 {
			t.Fatalf("requirements lost: got=%+v want=%+v", view, sample.Requirements)
		}
	}
}

func TestAutopilotRejectsUnboundedOrInvalidTraitMetadata(t *testing.T) {
	for _, requirements := range []production.Requirements{
		{ToolChoiceMode: "private-free-form-tool-name"},
		{MinPrefixCacheProtocol: -1},
	} {
		tracker := production.DemandTracker{}
		now := time.Now()
		tracker.Record(production.DemandSample{Requirements: requirements, Model: "model", PromptTokens: 100,
			RequestedMaxTokens: 64, ReceivedAt: now}, now, time.Minute)
		if len(tracker.ShapeSnapshot(now, time.Minute)) != 0 {
			t.Fatal("invalid trait metadata entered demand")
		}
	}
}
