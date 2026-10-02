package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"reflect"
	"testing"
	"time"
)

func TestAutopilotInventoryShadowIsNotServingPermission(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, true)
	p := autopilotControllerProvider(t, r, "shadow", now, autopilotTestDonor)
	p.mu.Lock()
	p.Models[0].WeightHash = "cached"
	p.autopilotInventory = []protocol.ModelInfo{p.Models[0]}
	p.autopilotOnlyModels = map[string]bool{autopilotTestTarget: true}
	p.mu.Unlock()
	beforeCapacity := r.ModelCapacitySnapshot()
	beforeModels := append([]protocol.ModelInfo(nil), p.Models...)
	if r.providerServesCatalogModelLocked(p, autopilotTestTarget) || r.providerServesOwnedRoutableModelLocked(p, autopilotTestTarget) {
		t.Fatal("shadow inventory granted public or owner serving permission")
	}
	if r.ColdSpillProviders(autopilotTestTarget, RequestTraits{}, false) != 0 {
		t.Fatal("shadow inventory became a cold-spill candidate")
	}
	if actions := r.reservePendingModelLoads([]modelLoadAction{{providerID: p.ID, modelID: autopilotTestTarget}}, now); len(actions) != 0 {
		t.Fatal("ordinary warmup accepted observer-only model")
	}
	action := planAutopilotAction(r.autopilotFleetSnapshot(c, now), c.config, now)
	if action == nil || action.Load != autopilotTestTarget {
		t.Fatalf("shadow lost candidate metadata: %+v", action)
	}
	if !reflect.DeepEqual(beforeModels, p.Models) || !reflect.DeepEqual(beforeCapacity, r.ModelCapacitySnapshot()) || len(r.pendingModelLoads) != 0 {
		t.Fatal("planning changed live serving state")
	}
	if !r.providerServesCatalogModelLocked(p, autopilotTestDonor) {
		t.Fatal("selected model stopped serving")
	}
}

func TestAutopilotInventoryRequiresAcknowledgedUnexpiredLiveControl(t *testing.T) {
	r, _, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "live", now, autopilotTestTarget)
	p.mu.Lock()
	p.autopilotOnlyModels = map[string]bool{autopilotTestTarget: true}
	p.mu.Unlock()
	if !r.providerServesCatalogModelLocked(p, autopilotTestTarget) {
		t.Fatal("acknowledged live control cannot serve resident candidate")
	}
	for _, mode := range []string{"expired", "shadow", "unacknowledged", "paused", "disabled"} {
		t.Run(mode, func(t *testing.T) {
			p.mu.Lock()
			defer p.mu.Unlock()
			p.autopilotControlUntil = now.Add(time.Hour)
			p.autopilotControlObserveOnly = false
			p.ModelAutopilot.Active = true
			p.ModelAutopilot.ObserveOnly = false
			p.ModelAutopilot.Paused = false
			p.ModelAutopilot.Enabled = true
			switch mode {
			case "expired":
				p.autopilotControlUntil = now.Add(-time.Second)
			case "shadow":
				p.autopilotControlObserveOnly = true
			case "unacknowledged":
				p.ModelAutopilot.Active = false
			case "paused":
				p.ModelAutopilot.Paused = true
			case "disabled":
				p.ModelAutopilot.Enabled = false
			}
			if r.providerServesCatalogModelLocked(p, autopilotTestTarget) || r.providerServesOwnedRoutableModelLocked(p, autopilotTestTarget) {
				t.Fatal("inactive control leaked serving permission")
			}
		})
	}
}

func TestAutopilotInventoryRegistrationPreservesNormalIdentity(t *testing.T) {
	r := New(testLogger())
	state := autopilotControllerState()
	normal := protocol.ModelInfo{ID: autopilotTestDonor, WeightHash: "selected"}
	observer := protocol.ModelInfo{ID: autopilotTestTarget, WeightHash: "cached"}
	p := r.Register("separate", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{normal}, ModelAutopilot: state, AutopilotInventory: []protocol.ModelInfo{observer, {ID: normal.ID, WeightHash: "wrong"}, {ID: "not-consented", WeightHash: "other"}}})
	if len(p.Models) != 2 || p.Models[0].WeightHash != "selected" || !p.autopilotOnlyModels[observer.ID] || p.autopilotOnlyModels[normal.ID] {
		t.Fatalf("inventory replaced ordinary identity: %+v", p.Models)
	}
	legacy := *state
	legacy.Protocol = 2
	old := r.Register("legacy", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{normal}, ModelAutopilot: &legacy, AutopilotInventory: []protocol.ModelInfo{observer}})
	if len(old.Models) != 1 || len(old.autopilotOnlyModels) != 0 {
		t.Fatal("legacy protocol gained observer permissions")
	}
	r.Disconnect(p.ID)
	fresh := r.Register("fresh", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{normal}, ModelAutopilot: state, AutopilotInventory: []protocol.ModelInfo{observer}})
	if providerOrdinaryModelAllowedLocked(fresh, observer.ID) {
		t.Fatal("reconnect inherited previous control")
	}
}

func TestAutopilotInventoryOnlyDeclaredSelectedSuccessorBecomesOrdinary(t *testing.T) {
	r, _, now := newAutopilotControllerTest(t, true)
	p := autopilotControllerProvider(t, r, "successor", now, autopilotTestDonor)
	p.mu.Lock()
	p.Models[0].WeightHash = "cached"
	p.autopilotInventory = []protocol.ModelInfo{p.Models[0]}
	p.autopilotOnlyModels = map[string]bool{autopilotTestTarget: true}
	p.mu.Unlock()
	if r.providerCanAcquireCatalogModelLocked(p, autopilotTestTarget) {
		t.Fatal("unrelated cached candidate was acquirable")
	}
	if !r.providerCanAcquireDesiredModelLocked(p, autopilotTestTarget, autopilotTestDonor) {
		t.Fatal("selected model's explicit successor lost the update path")
	}
	r.MergeProviderModels(p.ID, []protocol.ModelInfo{p.Models[0]})
	if !p.autopilotOnlyModels[autopilotTestTarget] {
		t.Fatal("plain metadata refresh promoted an observational candidate")
	}
	r.modelAliases = map[string]AliasTarget{"selected-alias": {Desired: autopilotTestTarget, Previous: autopilotTestDonor}}
	r.MergeProviderModels(p.ID, []protocol.ModelInfo{p.Models[0]})
	if p.autopilotOnlyModels[autopilotTestTarget] || !r.providerServesCatalogModelLocked(p, autopilotTestTarget) {
		t.Fatal("verified declared successor did not inherit ordinary selection")
	}
}

func TestAutopilotShadowProjectsDedicatedPermissionAfterActivation(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, true)
	p := autopilotControllerProvider(t, r, "dedicated", now, autopilotTestDonor)
	r.SetDedicatedModels([]string{autopilotTestDonor})
	p.mu.Lock()
	p.Models[0].WeightHash = "cached"
	p.autopilotOnlyModels = map[string]bool{autopilotTestTarget: true}
	p.mu.Unlock()
	// The user's current single-model serving set remains dedicated and useful.
	if !r.providerPassesRoutingGatesLocked(p, autopilotTestDonor, RequestTraits{}, false, now) {
		t.Fatal("shadow inventory destroyed the normal dedicated serving set")
	}
	// But a full live grant would make that permission set mixed. Do not claim
	// the donor survives such an activation in a hypothetical plan.
	if r.providerPassesAutopilotGatesLocked(p, p.Models[1], RequestTraits{}, now) {
		t.Fatal("shadow promised dedicated capacity that live permission would fence")
	}
	if planAutopilotAction(r.autopilotFleetSnapshot(c, now), c.config, now) != nil {
		t.Fatal("a plan ignored the dedicated resident lost on activation")
	}
}
