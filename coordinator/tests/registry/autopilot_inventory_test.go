package registry_test

import (
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotInventoryShadowIsNotServingPermission(t *testing.T) {
	var planner *production.ReservationPlanner
	r, c, now := newAutopilotControllerTest(t, true, func(deps *production.Dependencies) {
		deps.Reservations = func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		}
	})
	p := autopilotControllerProvider(t, r, "shadow", now, autopilotTestDonor)
	p.Mu().Lock()
	p.Models[0].WeightHash = "cached"
	r.states[p.ID].RegisterInventory(p.Models[1:], []protocol.ModelInfo{p.Models[0]}, p.ModelAutopilot)
	p.Mu().Unlock()
	beforeCapacity := r.ModelCapacitySnapshot()
	beforeModels := append([]protocol.ModelInfo(nil), p.Models...)
	eligibility := planner.PrepareEligibility()
	serves := eligibility.ServesCatalog(p.ID, autopilotTestTarget) || eligibility.ServesOwned(p.ID, autopilotTestTarget)
	eligibility.Close()
	if serves {
		t.Fatal("shadow inventory granted public or owner serving permission")
	}
	if r.ColdSpillProviders(autopilotTestTarget, production.RequestTraits{}, false) != 0 {
		t.Fatal("shadow inventory became a cold-spill candidate")
	}
	if actions := r.loads.Reserve([]production.ModelLoadAction{{ProviderID: p.ID, ModelID: autopilotTestTarget}}, now); len(actions) != 0 {
		t.Fatal("ordinary warmup accepted observer-only model")
	}
	action := autopilotcontrol.Plan(c.Fleet(now), r.cfg, now)
	if action == nil || action.Load != autopilotTestTarget {
		t.Fatalf("shadow lost candidate metadata: %+v", action)
	}
	if !reflect.DeepEqual(beforeModels, p.Models) || !reflect.DeepEqual(beforeCapacity, r.ModelCapacitySnapshot()) || r.pendingLoads.Count() != 0 {
		t.Fatal("planning changed live serving state")
	}
	eligibility = planner.PrepareEligibility()
	serves = eligibility.ServesCatalog(p.ID, autopilotTestDonor)
	eligibility.Close()
	if !serves {
		t.Fatal("selected model stopped serving")
	}
}

func TestAutopilotInventoryRequiresAcknowledgedUnexpiredLiveControl(t *testing.T) {
	var planner *production.ReservationPlanner
	r, _, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
		deps.Reservations = func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		}
	})
	p := autopilotControllerProvider(t, r, "live", now, autopilotTestTarget)
	p.Mu().Lock()
	// Establish cached inventory, then clear the serving hash as in the original
	// gate input. Observer classification survives an attestation hash refresh.
	p.Models[0].WeightHash = "cached"
	r.states[p.ID].RegisterInventory(p.Models[1:], []protocol.ModelInfo{p.Models[0]}, p.ModelAutopilot)
	p.Mu().Unlock()
	r.UpdateModelWeightHashes(p.ID, map[string]string{autopilotTestTarget: ""})
	eligibility := planner.PrepareEligibility()
	serves := eligibility.ServesCatalog(p.ID, autopilotTestTarget)
	eligibility.Close()
	if !serves {
		t.Fatal("acknowledged live control cannot serve resident candidate")
	}
	for _, mode := range []string{"expired", "shadow", "unacknowledged", "paused", "disabled"} {
		t.Run(mode, func(t *testing.T) {
			p.Mu().Lock()
			control := protocol.ModelAutopilotControl{Revision: "test", ExpiresAtMS: now.Add(time.Hour).UnixMilli()}
			p.ModelAutopilot.Active = true
			p.ModelAutopilot.ObserveOnly = false
			p.ModelAutopilot.Paused = false
			p.ModelAutopilot.Enabled = true
			consent := *p.ModelAutopilot
			switch mode {
			case "expired":
				control.ExpiresAtMS = now.Add(-time.Second).UnixMilli()
			case "shadow":
				control.ObserveOnly = true
			case "unacknowledged":
				p.ModelAutopilot.Active = false
			case "paused":
				p.ModelAutopilot.Paused = true
			case "disabled":
				p.ModelAutopilot.Enabled = false
			}
			r.states[p.ID].AcceptControl(&consent, control)
			p.Mu().Unlock()
			eligibility := planner.PrepareEligibility()
			serves := eligibility.ServesCatalog(p.ID, autopilotTestTarget) || eligibility.ServesOwned(p.ID, autopilotTestTarget)
			eligibility.Close()
			if serves {
				t.Fatal("inactive control leaked serving permission")
			}
		})
	}
}

func TestAutopilotInventoryRegistrationPreservesNormalIdentity(t *testing.T) {
	r, _ := newAutopilotFixture(autopilot.Config{})
	state := autopilotControllerState()
	normal := protocol.ModelInfo{ID: autopilotTestDonor, WeightHash: "selected"}
	observer := protocol.ModelInfo{ID: autopilotTestTarget, WeightHash: "cached"}
	p := r.Register("separate", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{normal}, ModelAutopilot: state, AutopilotInventory: []protocol.ModelInfo{observer, {ID: normal.ID, WeightHash: "wrong"}, {ID: "not-consented", WeightHash: "other"}}})
	if len(p.Models) != 2 || p.Models[0].WeightHash != "selected" || !r.states[p.ID].ObserverOnly(observer.ID) || r.states[p.ID].ObserverOnly(normal.ID) {
		t.Fatalf("inventory replaced ordinary identity: %+v", p.Models)
	}
	legacy := *state
	legacy.Protocol = 2
	old := r.Register("legacy", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{normal}, ModelAutopilot: &legacy, AutopilotInventory: []protocol.ModelInfo{observer}})
	if len(old.Models) != 1 || r.states[old.ID].Inventory.Count() != 0 {
		t.Fatal("legacy protocol gained observer permissions")
	}
	r.Disconnect(p.ID)
	fresh := r.Register("fresh", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{normal}, ModelAutopilot: state, AutopilotInventory: []protocol.ModelInfo{observer}})
	if r.states[fresh.ID].OrdinaryAllowed(fresh.ModelAutopilot, fresh.ID, observer.ID, time.Now) {
		t.Fatal("reconnect inherited previous control")
	}
}

func TestAutopilotInventoryOnlyDeclaredSelectedSuccessorBecomesOrdinary(t *testing.T) {
	var planner *production.ReservationPlanner
	r, _, now := newAutopilotControllerTest(t, true, func(deps *production.Dependencies) {
		deps.Reservations = func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		}
	})
	p := autopilotControllerProvider(t, r, "successor", now, autopilotTestDonor)
	p.Mu().Lock()
	p.Models[0].WeightHash = "cached"
	r.states[p.ID].RegisterInventory(p.Models[1:], []protocol.ModelInfo{p.Models[0]}, p.ModelAutopilot)
	p.Mu().Unlock()
	eligibility := planner.PrepareEligibility()
	acquires := eligibility.CanAcquire(p.ID, autopilotTestTarget)
	desired := eligibility.CanAcquireDesired(p.ID, autopilotTestTarget, autopilotTestDonor)
	eligibility.Close()
	if acquires {
		t.Fatal("unrelated cached candidate was acquirable")
	}
	if !desired {
		t.Fatal("selected model's explicit successor lost the update path")
	}
	r.MergeProviderModels(p.ID, []protocol.ModelInfo{p.Models[0]})
	if !r.states[p.ID].ObserverOnly(autopilotTestTarget) {
		t.Fatal("plain metadata refresh promoted an observational candidate")
	}
	r.SetModelAliases(map[string]production.AliasTarget{"selected-alias": {Desired: autopilotTestTarget, Previous: autopilotTestDonor}})
	r.MergeProviderModels(p.ID, []protocol.ModelInfo{p.Models[0]})
	eligibility = planner.PrepareEligibility()
	serves := eligibility.ServesCatalog(p.ID, autopilotTestTarget)
	eligibility.Close()
	if r.states[p.ID].ObserverOnly(autopilotTestTarget) || !serves {
		t.Fatal("verified declared successor did not inherit ordinary selection")
	}
}

func TestAutopilotShadowProjectsDedicatedPermissionAfterActivation(t *testing.T) {
	var planner *production.ReservationPlanner
	r, c, now := newAutopilotControllerTest(t, true, func(deps *production.Dependencies) {
		deps.Reservations = func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		}
	})
	p := autopilotControllerProvider(t, r, "dedicated", now, autopilotTestDonor)
	r.SetDedicatedModels([]string{autopilotTestDonor})
	p.Mu().Lock()
	p.Models[0].WeightHash = "cached"
	r.states[p.ID].RegisterInventory(p.Models[1:], []protocol.ModelInfo{p.Models[0]}, p.ModelAutopilot)
	p.Mu().Unlock()
	// The user's current single-model serving set remains dedicated and useful.
	eligibility := planner.PrepareEligibility()
	routes, _ := eligibility.Routing(p.ID, autopilotTestDonor, production.RequestTraits{}, false, now, false, false)
	projects := eligibility.AutopilotGates(p.ID, p.Models[1], production.RequestTraits{}, now)
	eligibility.Close()
	if !routes {
		t.Fatal("shadow inventory destroyed the normal dedicated serving set")
	}
	// But a full live grant would make that permission set mixed. Do not claim
	// the donor survives such an activation in a hypothetical plan.
	if projects {
		t.Fatal("shadow promised dedicated capacity that live permission would fence")
	}
	if autopilotcontrol.Plan(c.Fleet(now), r.cfg, now) != nil {
		t.Fatal("a plan ignored the dedicated resident lost on activation")
	}
}
