package registry_test

import (
	"cmp"
	"context"
	"encoding/json"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAutopilotShadowLeasePlansWithoutChangingResidencyOrLegacyAdmission(t *testing.T) {
	posture := newDeadlineObservations()
	pendingLoads := &pendingload.Ledger{}
	w := newWriterFixture(0, 8, nil, nil, nil, nil)
	var warmFleet func(time.Time) map[string]warmplan.Fleet
	var residencyCommands, legacyLoads int
	var interceptLegacyLoad bool
	r, c, now := newAutopilotControllerTest(t, true, posture.configure, func(deps *production.Dependencies) {
		deps.PendingLoads = pendingLoads
		deps.Connections = autopilotDeliveryWriters{"shadow": w}
		deps.AutopilotSender = func(string, protocol.ModelAutopilotMessage) error { residencyCommands++; return nil }
		deps.WarmPlanning = func(input warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
			warmFleet = input.Fleet
			return warmplan.NewController(input)
		}
		deps.ModelCommands = func(_ string, actual production.ModelCommandTransport) production.ModelCommandTransport {
			return modelCommandWriteFunc(func(ctx context.Context, data []byte) error {
				if !interceptLegacyLoad {
					return actual.WriteText(ctx, data)
				}
				var command protocol.LoadModelMessage
				if err := json.Unmarshal(data, &command); err != nil {
					return err
				}
				if command.Type == protocol.TypeLoadModel {
					legacyLoads++
				}
				return nil
			})
		}
	})
	p := autopilotControllerProvider(t, r, "shadow", now, autopilotTestDonor)
	// The sequence-establishing heartbeat is fixture setup, not placement work.
	posture.forProvider(p.ID).Reset()
	t.Cleanup(func() { w.Close(); w.Run() })
	p.CurrentModel = autopilotTestDonor
	beforeCapacity, _ := json.Marshal(p.BackendCapacity)
	beforeState, _ := json.Marshal(p.ModelAutopilot)
	beforePublic := r.ModelCapacitySnapshot()
	beforeFleet := warmFleet(now)
	beforeCold := r.ColdSpillProviders(autopilotTestTarget, production.RequestTraits{}, false)
	if !r.AutopilotSnapshot().ObserveOnly {
		t.Fatal("admin snapshot hides shadow mode before the first tick")
	}
	summary := c.Tick(now)
	if !summary.ObserveOnly || summary.Proposed != 1 || summary.Issued != 0 || residencyCommands != 0 {
		t.Fatalf("shadow did not produce an inert useful plan: %+v", summary)
	}
	var control protocol.ModelAutopilotControl
	select {
	case frame := <-w.lanes.Receive(true):
		if err := json.Unmarshal(w.executeFrame(frame), &control); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatal("provider cannot acknowledge shadow without a mode lease")
	}
	if !control.Enabled || !control.ObserveOnly || control.SessionID != p.ID || control.ExpiresAtMS <= now.UnixMilli() || w.lanes.Depth(true) != 0 {
		t.Fatalf("shadow acquired live authority or sent another command: %+v", control)
	}
	afterCapacity, _ := json.Marshal(p.BackendCapacity)
	afterState, _ := json.Marshal(p.ModelAutopilot)
	_, pending := r.states[p.ID].PrepareDelivery()
	if string(beforeCapacity) != string(afterCapacity) || string(beforeState) != string(afterState) ||
		p.CurrentModel != autopilotTestDonor || !reflect.DeepEqual(p.WarmModels, []string{autopilotTestDonor}) ||
		pending || pendingLoads.Count() != 0 || !posture.forProvider(p.ID).lastActivity().IsZero() {
		t.Fatal("hypothetical plan mutated residency, pending loads or deadline activity")
	}
	afterPublic := r.ModelCapacitySnapshot()
	slices.SortFunc(beforePublic, func(a, b production.ModelCapacity) int { return cmp.Compare(a.ModelID, b.ModelID) })
	slices.SortFunc(afterPublic, func(a, b production.ModelCapacity) int { return cmp.Compare(a.ModelID, b.ModelID) })
	afterFleet := warmFleet(now)
	afterCold := r.ColdSpillProviders(autopilotTestTarget, production.RequestTraits{}, false)
	if !reflect.DeepEqual(beforePublic, afterPublic) || !reflect.DeepEqual(beforeFleet, afterFleet) || beforeCold != 1 || afterCold != beforeCold {
		t.Fatalf("shadow lease changed public capacity or legacy warm/cold planning: public=%+v/%+v fleet=%+v/%+v cold=%d/%d", beforePublic, afterPublic, beforeFleet, afterFleet, beforeCold, afterCold)
	}
	if !r.events.Flush(r.store, testLogger()) {
		t.Fatal("proposed event could not be persisted")
	}
	ledger, ok := store.As[store.AutopilotStore](r.store)
	if !ok {
		t.Fatal("test store has no Autopilot ledger")
	}
	events, err := ledger.AutopilotRecords(context.Background(), time.Time{}, 10)
	if err != nil || len(events) != 1 || events[0].Phase != "proposed" || events[0].Load != autopilotTestTarget {
		t.Fatalf("shadow plan not distinguishable from actual commands: events=%+v error=%v", events, err)
	}
	// Legacy proactive warming still reserves and sends after a shadow lease.
	interceptLegacyLoad = true
	actions := r.loads.Reserve([]production.ModelLoadAction{{ProviderID: p.ID, ModelID: autopilotTestTarget}}, now)
	r.loads.Send(actions)
	if len(actions) != 1 || legacyLoads != 1 {
		t.Fatal("shadow enrollment took ownership from legacy load_model")
	}
}

func TestAutopilotShadowCannotAcquireLiveAuthorityFromResumeOrProviderAck(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, true)
	p := autopilotControllerProvider(t, r, "shadow", now)
	if !r.SetAutopilotPaused(true) || !r.SetAutopilotPaused(false) {
		t.Fatal("configured controller did not accept pause/resume")
	}
	p.Mu().Lock()
	p.ModelAutopilot.Active = true
	p.ModelAutopilot.ObserveOnly = false // inconsistent or forged live acknowledgement
	managed := r.states[p.ID].Managed(p.ModelAutopilot, p.ID, time.Now())
	blocked := r.states[p.ID].LegacyChangesBlocked(p.ModelAutopilot, p.ID, time.Now) || r.states[p.ID].RoutingBlocked(p.ModelAutopilot, p.ID, autopilotTestTarget, p.BackendCapacity, time.Now)
	p.Mu().Unlock()
	if managed || blocked || !r.AutopilotSnapshot().ObserveOnly {
		t.Fatal("shadow lease or admin resume acquired live mutation/routing authority")
	}
	if _, ok := c.Reserve(autopilotControllerPlan(t, r, c, now), now); ok {
		t.Fatal("shadow controller reserved a residency operation")
	}
}
