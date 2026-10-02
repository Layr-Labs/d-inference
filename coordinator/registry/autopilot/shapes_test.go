package autopilot

import (
	"testing"
	"time"
)

func TestAutopilotShapesKeepOrdinaryRequestsIndependent(t *testing.T) {
	d := DemandTracker{}
	now := time.Now()
	ordinary := DemandSample{Model: "mixed", ReceivedAt: now.Add(-time.Second), PromptTokens: 100, RequestedMaxTokens: 128}
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
	a, b := shapes[ShapeKey(ordinary)], shapes[ShapeKey(special)]
	if a.RequiresVision || a.HasTools || a.Requests != 20 || !b.RequiresVision || b.Requests != 1 {
		t.Fatalf("shape requirements leaked: %+v", shapes)
	}
	node := Node{ID: "plain", Residents: []string{"mixed"}}
	node.Fits = map[string]ModelFit{ShapeKey(ordinary): ModelFit{Rate: 10, ServiceSeconds: 1, MeetsDeadline: true}}
	capacity := NodeContribution(node, node.Residents, shapes)
	if capacity[ShapeKey(ordinary)] <= 0 || capacity[ShapeKey(special)] != 0 {
		t.Fatalf("capacity=%+v", capacity)
	}
}

func TestAutopilotCohortsRetainEveryHardRequirementAcrossBuckets(t *testing.T) {
	now := time.Now()
	tracker := DemandTracker{}
	var samples []DemandSample
	for flags := 0; flags < 16; flags++ {
		for _, mode := range []string{"", "auto", "none", "required", "named"} {
			for prefix := 0; prefix < 2; prefix++ {
				sample := DemandSample{Model: "same-build", PromptTokens: 100, RequestedMaxTokens: 64,
					Requirements: Requirements{RequiresVision: flags&1 != 0, HasTools: flags&2 != 0,
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
		view := views[ShapeKey(sample)]
		if view.Requirements != sample.Requirements || view.Requests != 2 {
			t.Fatalf("requirements lost: got=%+v want=%+v", view, sample.Requirements)
		}
	}
}

func TestAutopilotRejectsUnboundedOrInvalidTraitMetadata(t *testing.T) {
	for _, requirements := range []Requirements{
		{ToolChoiceMode: "private-free-form-tool-name"},
		{MinPrefixCacheProtocol: -1},
	} {
		tracker := DemandTracker{}
		now := time.Now()
		tracker.Record(DemandSample{Requirements: requirements, Model: "model", PromptTokens: 100,
			RequestedMaxTokens: 64, ReceivedAt: now}, now, time.Minute)
		if len(tracker.ShapeSnapshot(now, time.Minute)) != 0 {
			t.Fatal("invalid trait metadata entered demand")
		}
	}
}
