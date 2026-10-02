package registry

import (
	"cmp"
	"context"
	"encoding/json"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAutopilotShadowLeasePlansWithoutChangingResidencyOrLegacyAdmission(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, true)
	p := autopilotControllerProvider(t, r, "shadow", now, autopilotTestDonor)
	w := &providerWriter{control: make(chan *providerWriteRequest, 8), stop: make(chan struct{}), done: make(chan struct{})}
	p.writer = w
	t.Cleanup(func() { w.closeNow(); close(w.done) })
	p.CurrentModel = autopilotTestDonor
	beforeCapacity, _ := json.Marshal(p.BackendCapacity)
	beforeState, _ := json.Marshal(p.ModelAutopilot)
	beforePublic := r.ModelCapacitySnapshot()
	beforeFleet := r.warmPoolFleetSnapshot(now)
	beforeCold := r.ColdSpillProviders(autopilotTestTarget, RequestTraits{}, false)
	var residencyCommands int
	r.autopilotSender = func(string, protocol.ModelAutopilotMessage) error { residencyCommands++; return nil }
	if !r.AutopilotSnapshot().ObserveOnly {
		t.Fatal("admin snapshot hides shadow mode before the first tick")
	}
	summary := c.tick(now)
	if !summary.ObserveOnly || summary.Proposed != 1 || summary.Issued != 0 || residencyCommands != 0 {
		t.Fatalf("shadow did not produce an inert useful plan: %+v", summary)
	}
	var control protocol.ModelAutopilotControl
	select {
	case frame := <-w.control:
		if err := json.Unmarshal(frame.data, &control); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatal("provider cannot acknowledge shadow without a mode lease")
	}
	if !control.Enabled || !control.ObserveOnly || control.SessionID != p.ID || control.ExpiresAtMS <= now.UnixMilli() || len(w.control) != 0 {
		t.Fatalf("shadow acquired live authority or sent another command: %+v", control)
	}
	afterCapacity, _ := json.Marshal(p.BackendCapacity)
	afterState, _ := json.Marshal(p.ModelAutopilot)
	if string(beforeCapacity) != string(afterCapacity) || string(beforeState) != string(afterState) ||
		p.CurrentModel != autopilotTestDonor || !reflect.DeepEqual(p.WarmModels, []string{autopilotTestDonor}) ||
		p.autopilotPending != nil || len(r.pendingModelLoads) != 0 || !p.deadlineActivityAt.IsZero() {
		t.Fatal("hypothetical plan mutated residency, pending loads or deadline activity")
	}
	afterPublic := r.ModelCapacitySnapshot()
	slices.SortFunc(beforePublic, func(a, b ModelCapacity) int { return cmp.Compare(a.ModelID, b.ModelID) })
	slices.SortFunc(afterPublic, func(a, b ModelCapacity) int { return cmp.Compare(a.ModelID, b.ModelID) })
	afterFleet := r.warmPoolFleetSnapshot(now)
	afterCold := r.ColdSpillProviders(autopilotTestTarget, RequestTraits{}, false)
	if !reflect.DeepEqual(beforePublic, afterPublic) || !reflect.DeepEqual(beforeFleet, afterFleet) || beforeCold != 1 || afterCold != beforeCold {
		t.Fatalf("shadow lease changed public capacity or legacy warm/cold planning: public=%+v/%+v fleet=%+v/%+v cold=%d/%d", beforePublic, afterPublic, beforeFleet, afterFleet, beforeCold, afterCold)
	}
	if !r.flushAutopilotEvents() {
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
	var legacyLoads int
	r.loadModelSender = func(string, string) error { legacyLoads++; return nil }
	actions := r.reservePendingModelLoads([]modelLoadAction{{providerID: p.ID, modelID: autopilotTestTarget}}, now)
	r.sendModelLoadActions(actions)
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
	p.mu.Lock()
	p.ModelAutopilot.Active = true
	p.ModelAutopilot.ObserveOnly = false // inconsistent or forged live acknowledgement
	managed := providerAutopilotManagedLocked(p)
	blocked := providerLegacyModelChangesBlockedLocked(p) || providerAutopilotRoutingBlockedLocked(p, autopilotTestTarget)
	p.mu.Unlock()
	if managed || blocked || !r.AutopilotSnapshot().ObserveOnly {
		t.Fatal("shadow lease or admin resume acquired live mutation/routing authority")
	}
	if _, ok := r.reserveAutopilotAction(c, autopilotControllerPlan(t, r, c, now), now); ok {
		t.Fatal("shadow controller reserved a residency operation")
	}
}
