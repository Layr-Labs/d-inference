package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func managedProviderState(active string) *protocol.ModelAutopilotState {
	return &protocol.ModelAutopilotState{Protocol: 1, Enabled: true, CachedOnly: true, ActiveCommandID: active, MaxModelSlots: 3}
}

func TestAutopilotRoutingFencePreservesWarmAndLegacyCapacity(t *testing.T) {
	for _, tc := range []struct {
		name    string
		managed bool
		warm    bool
		active  string
		allowed bool
	}{
		{"legacy cold", false, false, "", true},
		{"legacy warm", false, true, "", true},
		{"managed cold", true, false, "", false},
		{"managed warm", true, true, "", true},
		{"managed transition warm", true, true, "operation", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			model := "managed-routing-model"
			p := makeSchedulerProvider(t, reg, "provider", model, 80)
			p.mu.Lock()
			if !tc.warm {
				p.BackendCapacity.Slots = nil
			}
			if tc.managed {
				p.ModelAutopilot = managedProviderState(tc.active)
			}
			p.mu.Unlock()
			candidates, capacity, tooLarge := reg.QuickCapacityCheck(model, 32, 64, RequestTraits{})
			if tc.allowed && candidates != 1 {
				t.Fatalf("warm/legacy capacity lost: candidates=%d capacity=%d tooLarge=%d", candidates, capacity, tooLarge)
			}
			if !tc.allowed && (candidates != 0 || capacity != 1 || tooLarge != 0) {
				t.Fatalf("managed fence must be transient capacity: candidates=%d capacity=%d tooLarge=%d", candidates, capacity, tooLarge)
			}
			pr := &PendingRequest{RequestID: "logical-request", Model: model, EstimatedPromptTokens: 32, RequestedMaxTokens: 64}
			winner, decision := reg.ReserveProviderEx(model, pr)
			if (winner != nil) != tc.allowed {
				t.Fatalf("reserve=%v allowed=%v decision=%+v", winner, tc.allowed, decision)
			}
			if !tc.allowed && decision.CapacityRejections != 1 {
				t.Fatalf("normal dispatch lost capacity classification: %+v", decision)
			}
		})
	}
}

func TestAutopilotRoutingFenceDoesNotBlockPlannerStructuralEligibility(t *testing.T) {
	reg := New(testLogger())
	model := "managed-planning-model"
	p := makeWarmPoolColdProvider(t, reg, "provider", model, 80, 64, 0)
	p.mu.Lock()
	p.ModelAutopilot = managedProviderState("")
	p.mu.Unlock()
	reg.mu.RLock()
	p.mu.Lock()
	structural := reg.providerPassesRoutingGatesLocked(p, model, RequestTraits{}, false, time.Now())
	admit := reg.providerCanAdmitLockedEx(p, model, RequestTraits{}, false, false, time.Now())
	p.mu.Unlock()
	reg.mu.RUnlock()
	if !structural || admit {
		t.Fatalf("planner must see managed cold inventory without admitting inference: structural=%v admit=%v", structural, admit)
	}
}

func TestAutopilotCachedPlanRevalidatesManagedTransitionsAndColdResidency(t *testing.T) {
	for _, active := range []bool{false, true} {
		t.Run(map[bool]string{false: "became cold", true: "started transition"}[active], func(t *testing.T) {
			reg := New(testLogger())
			model := "managed-plan-model"
			planTestProvider(t, reg, "primary", model, 0)
			alternate := planTestProvider(t, reg, "alternate", model, 400)
			pr := planTestRequest("primary-request", 32, 64)
			pr.Model = model
			winner, _, plan := reg.ReserveProviderWithPlan(model, pr)
			if winner == nil || winner.ID != "primary" || plan == nil || plan.Len() != 1 {
				t.Fatalf("fixture must retain warm alternate: winner=%v plan=%v", winner, plan)
			}
			alternate.mu.Lock()
			alternate.ModelAutopilot = managedProviderState("")
			if active {
				alternate.ModelAutopilot.ActiveCommandID = "operation"
			} else {
				alternate.BackendCapacity.Slots = nil
			}
			alternate.mu.Unlock()
			retry := planTestRequest("retry-request", 32, 64)
			retry.Model = model
			got, _, skips := reg.ReserveNextFromPlan(retry, plan, "primary")
			if got != nil || len(skips) == 0 {
				t.Fatalf("cached plan bypassed current management: provider=%v skips=%v", got, skips)
			}
			alternate.mu.Lock()
			pending := alternate.pendingCount()
			alternate.mu.Unlock()
			if pending != 0 {
				t.Fatalf("rejected cached plan reserved %d requests", pending)
			}
		})
	}
}

func TestAutopilotManagedProviderCannotReceiveLegacyModelChanges(t *testing.T) {
	reg := New(testLogger())
	model := "managed-legacy-model"
	p := makeWarmPoolColdProvider(t, reg, "managed", model, 80, 64, 0)
	p.mu.Lock()
	p.ModelAutopilot = managedProviderState("")
	p.mu.Unlock()
	sent := captureWarmPoolLoads(reg)
	reg.ConfigureWarmPool(testWarmPoolConfig())
	reg.RecordWarmPoolCapacityReject(model)
	reg.warmPool.tick(time.Now())
	if len(*sent) != 0 {
		t.Fatalf("legacy warm pool sent managed load: %+v", *sent)
	}
	if actions := reg.planModelLoadActions([]string{model}, time.Now()); len(actions) != 0 {
		t.Fatalf("queue swap planned managed provider: %+v", actions)
	}
	if actions := reg.reservePendingModelLoads([]modelLoadAction{{providerID: p.ID, modelID: model}}, time.Now()); len(actions) != 0 {
		t.Fatalf("legacy reservation bypassed opt-in: %+v", actions)
	}
	if reg.ColdSpillProviders(model, RequestTraits{}, false) != 0 {
		t.Fatal("cold spill promised a legacy managed load")
	}
	if err := reg.SendLoadModel(p.ID, model); err == nil {
		t.Fatal("legacy load command bypassed explicit placement")
	}
	if err := reg.SendPrefetchModel(p.ID, model, 1); err == nil {
		t.Fatal("legacy prefetch command bypassed cached-only consent")
	}
	var desired []protocol.DesiredModelEntry
	reg.desiredModelsSender = func(_ string, entries []protocol.DesiredModelEntry) error {
		desired = append([]protocol.DesiredModelEntry{}, entries...)
		return nil
	}
	if err := reg.SendDesiredModels(p.ID, []protocol.DesiredModelEntry{{ModelName: "alias", DesiredBuild: model}}); err != nil {
		t.Fatal(err)
	}
	if len(desired) != 1 || desired[0].DesiredBuild != model {
		t.Fatalf("catalog release updates must remain available under provider-serialized migration: %+v", desired)
	}
}

func TestAutopilotTransitionCannotBypassWithOwnerNetworkRouting(t *testing.T) {
	reg := New(testLogger())
	model := "managed-owner-model"
	p := makeSchedulerProvider(t, reg, "provider", model, 80)
	p.mu.Lock()
	p.AccountID = "owner"
	p.ModelAutopilot = managedProviderState("operation")
	p.mu.Unlock()
	pr := &PendingRequest{RequestID: "owner-request", Model: model, EstimatedPromptTokens: 32, RequestedMaxTokens: 64, OwnerAccountID: "owner", SelfRouteOnly: true}
	if winner, _ := reg.ReserveProviderEx(model, pr); winner != nil {
		t.Fatal("owner network request bypassed an atomic placement transition")
	}
}
