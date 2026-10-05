package inference_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// cachePreloadDrift answers cache planning from the planner's actual preload
// controller. After the planner's first observation it applies change, so the
// commitment step sees whatever followed classification; observed, when set,
// replaces what that first observation reports.
type cachePreloadDrift struct {
	controller *promptcontract.PreloadController
	observed   func(promptcontract.PreloadPlanningState) promptcontract.PreloadPlanningState
	change     func()
	first      promptcontract.PreloadPlanningState
	calls      int
}

func (d *cachePreloadDrift) NoteDemand(identity promptcontract.PreloadDemandIdentity) bool {
	return d.controller.NoteDemand(identity)
}

func (d *cachePreloadDrift) PlanningState(identity promptcontract.PreloadDemandIdentity) promptcontract.PreloadPlanningState {
	state := d.controller.PlanningState(identity)
	d.calls++
	if d.calls != 1 {
		return state
	}
	d.first = state
	if d.observed != nil {
		state = d.observed(state)
	}
	if d.change != nil {
		d.change()
	}
	return state
}

func TestCachePreloadCommitRevalidatesRegistryAndObservation(t *testing.T) {
	for _, scenario := range []string{"unchanged", "revoke_after_classification", "restore_after_rejection", "catalog_change", "stop_after_observation", "unacknowledged", "nonparticipating"} {
		t.Run(scenario, func(t *testing.T) {
			s := newCachePlanningOwner(t)
			f := newCachePlanningUDSFixture(t, s.Owner, s.registry)
			input := f.input()
			_, verified := f.provisioner.VerifiedPreloadArtifacts()
			if len(verified) != 1 || verified[0].ModelID != f.model {
				t.Fatal("actual verified identity missing")
			}
			routingOff := func() {
				if err := s.registry.ConfigureCacheRouting(registry.CacheRoutingConfig{Mode: registry.CacheRoutingOff, ActivationPct: 100}); err != nil {
					t.Fatal(err)
				}
			}
			if scenario == "restore_after_rejection" {
				routingOff()
			}
			// The planner classifies, observes, and then commits. Each scenario's
			// drift lands after that first observation, or replaces its report.
			planner := s.NewCachePlanner()
			drift := &cachePreloadDrift{controller: planner.Preloader}
			planner.PreloadPlanning = drift
			want, decided := registry.CachePlanOutcome(""), false
			switch scenario {
			case "unchanged":
				want, decided = registry.CachePlanPlanned, true
			case "revoke_after_classification":
				drift.change = routingOff
				want, decided = registry.CachePlanOff, true
			case "restore_after_rejection":
				drift.change = func() { configureCachePreparationTest(t, s.registry) }
			case "catalog_change":
				drift.change = func() {
					s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: f.model, WeightHash: strings.Repeat("d", 64)}})
				}
				want, decided = registry.CachePlanIneligible, true
			case "stop_after_observation":
				drift.change = func() {
					f.controller.Close()
					routingOff()
				}
			case "unacknowledged":
				drift.observed = func(promptcontract.PreloadPlanningState) promptcontract.PreloadPlanningState {
					return promptcontract.PreloadPlanningState{}
				}
			case "nonparticipating":
				drift.observed = func(state promptcontract.PreloadPlanningState) promptcontract.PreloadPlanningState {
					state.Participating = false
					return state
				}
			}
			result := planner.PlanResult(context.Background(), input)
			if !drift.first.Acknowledged {
				t.Fatal("native acknowledgement control missing")
			}
			// The planner records a commitment that declined to decide as
			// preload_not_ready, and a decided one under its Registry outcome.
			undecided := s.observation.Metrics().Snapshot().Counters["exact_cache_planning_decision_total{reason=preload_not_ready}"]
			gotDecision := undecided == 0
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
	s := newCachePlanningOwner(t)
	f := newCachePlanningUDSFixture(t, s.Owner, s.registry)
	// The fixture verifies one model; its exact tuple comes from the real
	// provisioner handoff that cache planning reads.
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	if len(verified) != 1 || verified[0].ModelID != f.model {
		t.Fatal("actual verified identity missing")
	}
	identity := verified[0]
	// This test preserves the planning fixture's original outcomes; refusal
	// probing itself is side-effect-free. Demand never carries account/body
	// fields into selection.
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
