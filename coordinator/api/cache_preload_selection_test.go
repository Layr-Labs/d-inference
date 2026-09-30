package api

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCachePreloadCommitRevalidatesRegistryAndObservation(t *testing.T) {
	for _, scenario := range []string{"unchanged", "revoke_after_classification", "restore_after_rejection", "catalog_change", "stop_after_observation", "unacknowledged", "nonparticipating"} {
		t.Run(scenario, func(t *testing.T) {
			s := &Server{registry: registry.New(quietLogger()), metrics: NewMetrics()}
			f := newCachePlanningUDSFixture(t, s)
			input := f.input()
			status, exists := f.provisioner.Status(f.model)
			identity, verified := s.cachePreloadIdentity(f.model, status)
			if !exists || !verified {
				t.Fatal("actual verified identity missing")
			}
			planInput := registry.CachePlanInput{Account: input.Account, Model: input.Model, Body: input.Body,
				PromptContractID: status.PromptContractID, ModelAggregateSHA256: status.ModelAggregateSHA256}
			if scenario == "restore_after_rejection" {
				if err := s.registry.ConfigureCacheRouting(registry.CacheRoutingConfig{Mode: registry.CacheRoutingOff, ActivationPct: 100}); err != nil {
					t.Fatal(err)
				}
			}
			_, rejected := s.registry.CachePlanRejection(s.promptContract, planInput)
			observed := f.controller.PlanningState(identity)
			if !observed.Acknowledged {
				t.Fatal("native acknowledgement control missing")
			}
			want, decided := registry.CachePlanOutcome(""), false
			switch scenario {
			case "unchanged":
				want, decided = registry.CachePlanPlanned, true
			case "revoke_after_classification":
				if err := s.registry.ConfigureCacheRouting(registry.CacheRoutingConfig{Mode: registry.CacheRoutingOff, ActivationPct: 100}); err != nil {
					t.Fatal(err)
				}
				want, decided = registry.CachePlanOff, true
			case "restore_after_rejection":
				configureCachePreparationTest(t, s.registry)
			case "catalog_change":
				s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: f.model, WeightHash: strings.Repeat("d", 64)}})
				want, decided = registry.CachePlanIneligible, true
			case "stop_after_observation":
				f.controller.Close()
				if err := s.registry.ConfigureCacheRouting(registry.CacheRoutingConfig{Mode: registry.CacheRoutingOff, ActivationPct: 100}); err != nil {
					t.Fatal(err)
				}
			case "unacknowledged":
				observed = promptcontract.PreloadPlanningState{}
			case "nonparticipating":
				observed.Participating = false
			}
			result, gotDecision := s.commitCachePlanning(context.Background(), input, planInput, identity, rejected, observed)
			if gotDecision != decided || result.Outcome != want {
				t.Fatalf("commit = %+v/%t, want %s/%t", result, gotDecision, want, decided)
			}
			activation := s.registry.CacheRoutingActivationStatus()
			plans := f.state(t).Plans
			if scenario == "unchanged" {
				if activation.Evaluated != 1 || activation.Admitted != 1 || plans != 1 || result.Plan.CacheScope == "" {
					t.Fatal("one valid decision did not activate and plan exactly once")
				}
			} else if activation.Evaluated != 0 || plans != 0 || result.SidecarCalled || result.Plan.CacheScope != "" {
				t.Fatal("drift/refusal promoted a nonparticipating observation into activation or Plan")
			}
		})
	}
}

func TestCachePreloadDemandExcludesCanceledExpiredAndMediaRefusals(t *testing.T) {
	s := &Server{registry: registry.New(quietLogger()), metrics: NewMetrics()}
	f := newCachePlanningUDSFixture(t, s)
	status, _ := f.provisioner.Status(f.model)
	identity, _ := s.cachePreloadIdentity(f.model, status)
	// This test preserves D48's original outcomes; refusal probing itself is
	// side-effect-free. Demand never carries account/body fields into selection.
	input := f.input()
	input.HasMedia = true
	before := s.registry.CacheRoutingActivationStatus()
	s.planCacheRoute(context.Background(), input)
	if s.registry.CacheRoutingActivationStatus().Evaluated != before.Evaluated || f.state(t).Plans != 0 {
		t.Fatal("media refusal consumed activation or submitted planner IO")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if cachePreloadDemandWithinDeadline(ctx, f.input()) {
		t.Fatal("canceled request could record demand")
	}
	expired := f.input()
	expired.ReceivedAt, expired.FirstContentBudget = time.Now().Add(-time.Second), time.Millisecond
	if cachePreloadDemandWithinDeadline(context.Background(), expired) {
		t.Fatal("expired original request clock could record demand")
	}
	expired.FirstContentBudget = 0
	if !cachePreloadDemandWithinDeadline(context.Background(), expired) {
		t.Fatal("exempt original clock was changed")
	}
	if !f.controller.PlanningState(identity).Acknowledged {
		t.Fatal("refusal destroyed native acknowledgement")
	}
}
