package autopilot_test

import (
	"math"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestQueuedDemandPreservesShapeWithoutRecordingArrivals(t *testing.T) {
	now := time.Now()
	sample := production.DemandSample{Model: "model", ReceivedAt: now, PromptTokens: 4000, RequestedMaxTokens: 2000,
		Requirements:  production.Requirements{RequiresVision: true, HasTools: true, RequiresNativeMediaTools: true, ToolChoiceMode: "none", MinPrefixCacheProtocol: 1},
		DeadlineKnown: true, FirstContentDeadline: 10 * time.Second}
	history := map[string]production.DemandView{}
	first := production.WithQueuedDemand(history, []production.DemandSample{sample})
	second := production.WithQueuedDemand(history, []production.DemandSample{sample})
	key := production.ShapeKey(sample)
	for _, view := range []production.DemandView{first[key], second[key]} {
		if view.Queued != 1 || view.Requests != 0 || view.Rate != 0 || view.Requirements != sample.Requirements ||
			view.TailPromptTokens != 4000 || view.RequestedMaxTokens != 2000 || view.DeadlineSeconds != 10 {
			t.Fatalf("queue projection lost eligibility or inflated arrivals: %+v", view)
		}
	}
	if len(history) != 0 {
		t.Fatal("snapshot mutated persistent demand")
	}
	if len(production.WithQueuedDemand(history, nil)) != 0 {
		t.Fatal("departed queue entry persisted")
	}
}

func TestQualifiedActiveAndQueuedCohortsCountEachRequestOnce(t *testing.T) {
	plain := production.DemandSample{Model: "model", PromptTokens: 100, RequestedMaxTokens: 64, DeadlineKnown: true}
	vision := plain
	vision.RequiresVision = true
	demand := production.WithActiveDemand(nil, []production.DemandSample{plain, plain, vision, vision, vision, vision})
	demand = production.WithQueuedDemand(demand, []production.DemandSample{plain, vision, vision, vision})
	plainKey, visionKey := production.ShapeKey(plain), production.ShapeKey(vision)
	f := production.Fleet{Demand: demand, Nodes: []production.Node{{Fits: map[string]production.ModelFit{
		plainKey: {Rate: 10, ServiceSeconds: 1, MeetsDeadline: true}, visionKey: {Rate: 10, ServiceSeconds: 1, MeetsDeadline: true},
	}}}}
	coverage := production.Coverage(f)
	if _, exists := coverage.Need["model"]; exists {
		t.Fatal("queued shapes created weaker base-model pressure")
	}
	if math.Abs(coverage.Need[plainKey]-3) > 1e-9 || math.Abs(coverage.Need[visionKey]-7) > 1e-9 {
		t.Fatalf("active work was duplicated across queued shapes: %+v", coverage.Need)
	}
}
