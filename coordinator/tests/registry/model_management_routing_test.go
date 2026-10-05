package registry_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func managedProviderState(p *production.Provider, owner *autopilotstate.State, active string) *protocol.ModelAutopilotState {
	until := time.Now().Add(time.Hour)
	models := []string{}
	for _, m := range p.Models {
		models = append(models, m.ID)
	}
	state := &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, Active: true, SessionID: p.ID, Revision: "test", SelectedModels: models, Enabled: true, CachedOnly: true, ActiveCommandID: active, MaxModelSlots: 3}
	owner.AcceptControl(state, protocol.ModelAutopilotControl{Revision: "test", ExpiresAtMS: until.UnixMilli()})
	return state
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
			reg, _ := newAutopilotFixture(autopilot.DefaultConfig())
			model := "managed-routing-model"
			p := makeSchedulerProvider(t, reg.Registry, "provider", model, 80)
			p.Mu().Lock()
			if !tc.warm {
				p.BackendCapacity.Slots = nil
			}
			if tc.managed {
				p.ModelAutopilot = managedProviderState(p, reg.states[p.ID], tc.active)
			}
			p.Mu().Unlock()
			candidates, capacity, tooLarge := reg.QuickCapacityCheck(model, 32, 64, production.RequestTraits{})
			if tc.allowed && candidates != 1 {
				t.Fatalf("warm/legacy capacity lost: candidates=%d capacity=%d tooLarge=%d", candidates, capacity, tooLarge)
			}
			if !tc.allowed && (candidates != 0 || capacity != 1 || tooLarge != 0) {
				t.Fatalf("managed fence must be transient capacity: candidates=%d capacity=%d tooLarge=%d", candidates, capacity, tooLarge)
			}
			pr := &production.PendingRequest{RequestID: "logical-request", Model: model, EstimatedPromptTokens: 32, RequestedMaxTokens: 64}
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
	var planner *production.ReservationPlanner
	reg, _ := newAutopilotFixture(autopilot.DefaultConfig(), func(deps *production.Dependencies) {
		deps.Reservations = func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		}
	})
	model := "managed-planning-model"
	p := makeWarmPoolColdProvider(t, reg.Registry, "provider", model, 80, 64, 0)
	p.Mu().Lock()
	p.ModelAutopilot = managedProviderState(p, reg.states[p.ID], "")
	p.Mu().Unlock()
	eligibility := planner.PrepareEligibility()
	structural, _ := eligibility.Routing(p.ID, model, production.RequestTraits{}, false, time.Now(), false, false)
	admit := eligibility.Admit(p.ID, model, production.RequestTraits{}, false, false, time.Now())
	eligibility.Close()
	if !structural || admit {
		t.Fatalf("planner must see managed cold inventory without admitting inference: structural=%v admit=%v", structural, admit)
	}
}

func TestAutopilotCachedPlanRevalidatesManagedTransitionsAndColdResidency(t *testing.T) {
	for _, active := range []bool{false, true} {
		t.Run(map[bool]string{false: "became cold", true: "started transition"}[active], func(t *testing.T) {
			histories := make(map[string]*measurements.History)
			reg, _ := newAutopilotFixture(autopilot.DefaultConfig(), func(deps *production.Dependencies) {
				deps.Measurements = func(id string) *measurements.History {
					history := &measurements.History{}
					histories[id] = history
					return history
				}
			})
			fixture := &planRegistryFixture{registry: reg.Registry, histories: histories}
			model := "managed-plan-model"
			fixture.provider(t, "primary", model, 0)
			alternate := fixture.provider(t, "alternate", model, 400)
			pr := planTestRequest("primary-request", 32, 64)
			pr.Model = model
			winner, _, plan := reg.ReserveProviderWithPlan(model, pr)
			if winner == nil || winner.ID != "primary" || plan == nil || plan.Len() != 1 {
				t.Fatalf("fixture must retain warm alternate: winner=%v plan=%v", winner, plan)
			}
			alternate.Mu().Lock()
			alternate.ModelAutopilot = managedProviderState(alternate, reg.states[alternate.ID], "")
			if active {
				alternate.ModelAutopilot.ActiveCommandID = "operation"
			} else {
				alternate.BackendCapacity.Slots = nil
			}
			alternate.Mu().Unlock()
			retry := planTestRequest("retry-request", 32, 64)
			retry.Model = model
			got, _, skips := reg.ReserveNextFromPlan(retry, plan, "primary")
			if got != nil || len(skips) == 0 {
				t.Fatalf("cached plan bypassed current management: provider=%v skips=%v", got, skips)
			}
			pending := alternate.PendingCount()
			if pending != 0 {
				t.Fatalf("rejected cached plan reserved %d requests", pending)
			}
		})
	}
}

func TestAutopilotManagedProviderCannotReceiveLegacyModelChanges(t *testing.T) {
	owner := autopilotstate.New(&autopilotstate.Lease{})
	var desired []protocol.DesiredModelEntry
	var desiredSender func([]protocol.DesiredModelEntry) error
	reg := newWarmRegistryWithDeps(t, func(deps *production.Dependencies) {
		deps.AutopilotState = func(string) *autopilotstate.State { return owner }
		deps.ModelCommands = func(_ string, actual production.ModelCommandTransport) production.ModelCommandTransport {
			return modelCommandWriteFunc(func(ctx context.Context, data []byte) error {
				var msg protocol.DesiredModelsMessage
				if err := json.Unmarshal(data, &msg); err != nil {
					return err
				}
				if msg.Type == protocol.TypeDesiredModels && desiredSender != nil {
					return desiredSender(msg.Models)
				}
				return actual.WriteText(ctx, data)
			})
		}
	})
	model := "managed-legacy-model"
	p := makeWarmPoolColdProvider(t, reg, "managed", model, 80, 64, 0)
	p.Mu().Lock()
	p.ModelAutopilot = managedProviderState(p, owner, "")
	p.Mu().Unlock()
	sent := captureWarmPoolLoads(reg)
	reg.ConfigureWarmPool(testWarmPoolConfig())
	reg.RecordWarmPoolCapacityReject(model)
	warmFixtureFor(reg).runtime.Tick(time.Now())
	if len(*sent) != 0 {
		t.Fatalf("legacy warm pool sent managed load: %+v", *sent)
	}
	if actions := warmFixtureFor(reg).loads.Plan([]string{model}, time.Now()); len(actions) != 0 {
		t.Fatalf("queue swap planned managed provider: %+v", actions)
	}
	if actions := warmFixtureFor(reg).loads.Reserve([]production.ModelLoadAction{{ProviderID: p.ID, ModelID: model}}, time.Now()); len(actions) != 0 {
		t.Fatalf("legacy reservation bypassed opt-in: %+v", actions)
	}
	if reg.ColdSpillProviders(model, production.RequestTraits{}, false) != 0 {
		t.Fatal("cold spill promised a legacy managed load")
	}
	if err := reg.SendLoadModel(p.ID, model); err == nil {
		t.Fatal("legacy load command bypassed explicit placement")
	}
	if err := reg.SendPrefetchModel(p.ID, model, 1); err == nil {
		t.Fatal("legacy prefetch command bypassed cached-only consent")
	}
	desiredSender = func(entries []protocol.DesiredModelEntry) error {
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
	reg, _ := newAutopilotFixture(autopilot.DefaultConfig())
	model := "managed-owner-model"
	p := makeSchedulerProvider(t, reg.Registry, "provider", model, 80)
	p.Mu().Lock()
	p.AccountID = "owner"
	p.ModelAutopilot = managedProviderState(p, reg.states[p.ID], "operation")
	p.Mu().Unlock()
	pr := &production.PendingRequest{RequestID: "owner-request", Model: model, EstimatedPromptTokens: 32, RequestedMaxTokens: 64, OwnerAccountID: "owner", SelfRouteOnly: true}
	if winner, _ := reg.ReserveProviderEx(model, pr); winner != nil {
		t.Fatal("owner network request bypassed an atomic placement transition")
	}
}
