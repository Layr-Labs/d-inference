package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestMixedModelRoutingAndCapacity(t *testing.T) {
	for _, model := range []string{gemmaBuild, gemmaBuildOrg, gemmaBuildSmol, qwenBuild} {
		t.Run(model, func(t *testing.T) {
			reg := production.New(testLogger())
			other := qwenBuild
			if model == qwenBuild {
				other = gemmaBuild
			}
			reg.SetModelCatalog([]production.CatalogEntry{{ID: model}, {ID: other}})
			single := makeSchedulerProvider(t, reg, "single", model, 40)
			mixed := makeSchedulerProvider(t, reg, "mixed", model, 400, other)
			count, _, _, _, _ := reg.QuickCapacityCheckWithTTFTForRequest(model, 50, 128, production.RequestTraits{}, false)
			if count != 2 {
				t.Fatalf("preflight candidates = %d, want both single and mixed providers", count)
			}
			req := &production.PendingRequest{RequestID: "first", Model: model, EstimatedPromptTokens: 50, RequestedMaxTokens: 128}
			selected, decision := reg.ReserveProviderEx(model, req)
			if selected != mixed || decision.CandidateCount != 2 {
				t.Fatalf("selected %v from %d candidates, want faster mixed provider", selected, decision.CandidateCount)
			}
			if decision.GateRejections[8] != 0 {
				t.Fatal("retired dedicated gate emitted a rejection")
			}
			selected.RemovePending(req.RequestID)

			fallback := &production.PendingRequest{RequestID: "fallback", Model: model, EstimatedPromptTokens: 50, RequestedMaxTokens: 128}
			selected, decision = reg.ReserveProviderEx(model, fallback, mixed.ID)
			if selected != single || decision.CandidateCount != 1 {
				t.Fatalf("excluded mixed provider selected %v from %d candidates, want single provider", selected, decision.CandidateCount)
			}
			selected.RemovePending(fallback.RequestID)
			if selected, _ := reg.ReserveProviderEx(model, req, mixed.ID, single.ID); selected != nil {
				t.Fatal("routing ignored explicit provider exclusions")
			}
		})
	}
}

func TestMixedModelOwnerRouteKeepsCatalogBoundary(t *testing.T) {
	reg := production.New(testLogger())
	reg.SetModelCatalog([]production.CatalogEntry{{ID: gemmaBuild}})
	mixed := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 80, qwenBuild)
	mixed.Mu().Lock()
	mixed.AccountID = "owner"
	mixed.Mu().Unlock()
	if count, _, _ := reg.QuickCapacityCheck(gemmaBuild, 0, 0, production.RequestTraits{}); count != 1 {
		t.Fatalf("catalog model on mixed provider has %d candidates, want 1", count)
	}
	if count, _, _ := reg.QuickCapacityCheck(qwenBuild, 0, 0, production.RequestTraits{}); count != 0 {
		t.Fatalf("off-catalog model has %d public candidates, want 0", count)
	}
	public := &production.PendingRequest{RequestID: "public", Model: qwenBuild, RequestedMaxTokens: 128}
	if selected := reg.ReserveProvider(qwenBuild, public); selected != nil {
		t.Fatal("public request reached an off-catalog model")
	}
	owner := &production.PendingRequest{RequestID: "owner", Model: qwenBuild, RequestedMaxTokens: 128, SelfRouteOnly: true, OwnerAccountID: "owner"}
	if selected := reg.ReserveProvider(qwenBuild, owner); selected != mixed {
		t.Fatalf("owner selected %v, want own mixed provider for off-catalog model", selected)
	}
	mixed.RemovePending(owner.RequestID)
	reg.SetModelCatalog([]production.CatalogEntry{{ID: gemmaBuild, WeightHash: "expected"}})
	reg.UpdateModelWeightHashes(mixed.ID, map[string]string{gemmaBuild: "mismatched"})
	for _, self := range []bool{false, true} {
		req := &production.PendingRequest{RequestID: "hash", Model: gemmaBuild, RequestedMaxTokens: 128, SelfRouteOnly: self, OwnerAccountID: "owner"}
		if selected := reg.ReserveProvider(gemmaBuild, req); selected != nil {
			t.Fatalf("self=%v bypassed catalog weight-hash mismatch", self)
		}
	}
}

func TestMixedModelAliasPrefersDesiredBuild(t *testing.T) {
	reg := production.New(testLogger())
	mixed := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 200, qwenBuild)
	previous := makeSchedulerProvider(t, reg, "previous", gemmaBuildSmol, 80)
	reg.SetModelAliases(map[string]production.AliasTarget{
		"gemma-4-26b": {Desired: gemmaBuild, Previous: gemmaBuildSmol},
	})
	build, alias, ok := reg.ResolveModel("gemma-4-26b")
	if !ok || !alias || build != gemmaBuild {
		t.Fatalf("resolved %q (alias=%v ok=%v), want desired build on mixed provider", build, alias, ok)
	}
	if selected := findRoutableProvider(reg, build); selected != mixed {
		t.Fatalf("desired build routed to %v, want mixed provider", selected)
	}
	reg.RecordDispatchLoadFailure(mixed.ID, gemmaBuild)
	build, alias, ok = reg.ResolveModel("gemma-4-26b")
	if !ok || !alias || build != gemmaBuildSmol {
		t.Fatalf("cooled desired resolved %q (alias=%v ok=%v), want previous build", build, alias, ok)
	}
	if selected := findRoutableProvider(reg, build); selected != previous {
		t.Fatalf("previous build routed to %v, want previous provider", selected)
	}
}

func TestMixedModelWarmAndLoadEligibility(t *testing.T) {
	for _, state := range []string{"running", "idle", "cold"} {
		t.Run(state, func(t *testing.T) {
			var planner *production.ModelLoadPlanner
			reg := production.NewWithDependencies(testLogger(), production.Dependencies{
				ModelLoadPlanning: func(p *production.ModelLoadPlanner) production.ModelLoadPlanning {
					planner = p
					return p
				},
			})
			providers := []*production.Provider{
				makeSchedulerProvider(t, reg, "single", gemmaBuild, 80),
				makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 80, qwenBuild),
			}
			for _, provider := range providers {
				provider.Mu().Lock()
				if state == "cold" {
					provider.BackendCapacity.Slots = nil
				} else {
					provider.BackendCapacity.Slots[0].State = state
				}
				provider.Mu().Unlock()
			}
			preparation := planner.Prepare()
			now := time.Now()
			for _, provider := range providers {
				if got := preparation.Warm(provider.ID, gemmaBuild, now); got != (state != "cold") {
					t.Errorf("provider %s warm=%v in state %s", provider.ID, got, state)
				}
				if _, reason := preparation.ColdCandidate(provider.ID, gemmaBuild, now); reason != warmplan.WarmColdEligible {
					t.Errorf("provider %s cold-load reason=%s, want eligible", provider.ID, reason)
				}
				if _, eligible := preparation.Candidate(provider.ID, gemmaBuild, now); !eligible {
					t.Errorf("provider %s rejected by swap planner", provider.ID)
				}
			}
			preparation.Close()
			wantCold := 0
			if state == "cold" {
				wantCold = len(providers)
			}
			if got := reg.ColdSpillProviders(gemmaBuild, production.RequestTraits{}, false); got != wantCold {
				t.Fatalf("cold-spill providers=%d, want %d", got, wantCold)
			}
		})
	}
}
