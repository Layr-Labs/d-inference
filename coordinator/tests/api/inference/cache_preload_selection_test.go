package inference_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
)

func TestCachePreloadDemandExcludesCanceledExpiredAndMediaRefusals(t *testing.T) {
	s := newCachePlanningOwner(t)
	f := newCachePlanningUDSFixture(t, s.Owner, s.registry)
	// The fixture verifies one model; its exact tuple comes from the real
	// provisioner handoff that cache planning reads.
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	if len(verified) != 1 || verified[0].ModelID != f.model {
		t.Fatal("actual verified identity missing")
	}
	identity := verified[0]
	// This test preserves D48's original outcomes; refusal probing itself is
	// side-effect-free. Demand never carries account/body fields into selection.
	input := f.input()
	input.HasMedia = true
	before := s.registry.CacheRoutingActivationStatus()
	s.NewCachePlanner().PlanResult(context.Background(), input)
	if s.registry.CacheRoutingActivationStatus().Evaluated != before.Evaluated || f.state(t).Plans != 0 {
		t.Fatal("media refusal consumed activation or submitted planner IO")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if routeplan.CachePreloadDemandWithinDeadline(ctx, f.input()) {
		t.Fatal("canceled request could record demand")
	}
	expired := f.input()
	expired.ReceivedAt, expired.FirstContentBudget = time.Now().Add(-time.Second), time.Millisecond
	if routeplan.CachePreloadDemandWithinDeadline(context.Background(), expired) {
		t.Fatal("expired original request clock could record demand")
	}
	expired.FirstContentBudget = 0
	if !routeplan.CachePreloadDemandWithinDeadline(context.Background(), expired) {
		t.Fatal("exempt original clock was changed")
	}
	if !f.controller.PlanningState(identity).Acknowledged {
		t.Fatal("refusal destroyed native acknowledgement")
	}
}
