package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func swapTestHeartbeat(model, state string) *protocol.HeartbeatMessage {
	active := model
	return &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "idle",
		ActiveModel: &active,
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots:         []protocol.BackendSlotCapacity{{Model: model, State: state}},
		},
	}
}

// swapTestCrashedHeartbeat reports the model's slot crashed — unroutable for
// the drain — with the given free_for_load_gb, which is what decides whether
// the swap planner may send load_model to reload it.
func swapTestCrashedHeartbeat(model string, freeForLoadGB float64) *protocol.HeartbeatMessage {
	hb := swapTestHeartbeat(model, "crashed")
	hb.BackendCapacity.FreeForLoadGB = &freeForLoadGB
	return hb
}

func swapTestQueued(id, model string) *QueuedRequest {
	return &QueuedRequest{
		RequestID:  id,
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:             id,
			Model:                 model,
			RequestedMaxTokens:    64,
			EstimatedPromptTokens: 32,
		},
	}
}

// trailingTimerStub replaces the gate's timer so a test fires the trailing
// plan by hand instead of waiting out real time (and so no real timer can fire
// into a fake-clock test).
type trailingTimerStub struct {
	waits []time.Duration
	fire  []func()
}

func installTrailingTimerStub(reg *Registry) *trailingTimerStub {
	s := &trailingTimerStub{}
	reg.swapPlanGate.afterFunc = func(d time.Duration, f func()) {
		s.waits = append(s.waits, d)
		s.fire = append(s.fire, f)
	}
	return s
}

// TestSwapPlanGateCoalescesBurstAndReopensAfterWindow pins the gate itself
// with an injected clock: 50 heartbeat triggers inside one window plan once
// (and arm exactly one trailing plan), the first trigger after the window
// plans again, and an empty queue never plans at all.
func TestSwapPlanGateCoalescesBurstAndReopensAfterWindow(t *testing.T) {
	reg := New(testLogger())
	reg.loadModelSender = func(string, string) error { return nil }
	const cold = "swap-gate-cold-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: cold, SizeGB: 8, MinRAMGB: 16}})
	makeSchedulerProvider(t, reg, "warm-other", "swap-gate-other-model", 100)
	stub := installTrailingTimerStub(reg)

	t0 := time.Now()
	// Empty queue: the planner is never consulted.
	for i := 0; i < 5; i++ {
		if reg.triggerModelSwapsFromHeartbeat(t0.Add(time.Duration(i) * time.Millisecond)) {
			t.Fatal("empty queue must not run the planner")
		}
	}
	if reg.swapPlanGate.planRuns() != 0 {
		t.Fatalf("plans with empty queue = %d, want 0", reg.swapPlanGate.planRuns())
	}
	if len(stub.fire) != 0 {
		t.Fatal("empty queue must not arm a trailing plan")
	}

	if err := reg.Queue().Enqueue(swapTestQueued("swap-gate-req", cold)); err != nil {
		t.Fatal(err)
	}
	planned := 0
	for i := 0; i < 50; i++ {
		if reg.triggerModelSwapsFromHeartbeat(t0.Add(time.Duration(i) * time.Millisecond)) {
			planned++
		}
	}
	if planned != 1 || reg.swapPlanGate.planRuns() != 1 {
		t.Fatalf("burst of 50 inside the window planned %d times (gate runs %d), want 1", planned, reg.swapPlanGate.planRuns())
	}
	if len(stub.waits) != 1 || stub.waits[0] != modelSwapPlanInterval-time.Millisecond {
		t.Fatalf("burst armed trailing plans %v, want exactly one timed for the window's end (%v)",
			stub.waits, modelSwapPlanInterval-time.Millisecond)
	}
	if !reg.triggerModelSwapsFromHeartbeat(t0.Add(modelSwapPlanInterval + time.Millisecond)) {
		t.Fatal("first heartbeat after the window must plan again")
	}
	if reg.swapPlanGate.planRuns() != 2 {
		t.Fatalf("gate runs = %d, want 2", reg.swapPlanGate.planRuns())
	}
	// Exactly at the boundary the window has not elapsed yet.
	if reg.triggerModelSwapsFromHeartbeat(t0.Add(modelSwapPlanInterval + time.Millisecond + modelSwapPlanInterval - time.Nanosecond)) {
		t.Fatal("a trigger inside the second window must be coalesced")
	}
}

// TestSwapPlanGateRefusedHeartbeatArmsOneTrailingPlan pins the trailing plan
// with an injected clock and timer: the first refused trigger of a window arms
// exactly one trailing plan timed for the window's end, later refused triggers
// do not arm another, firing it runs one plan and disarms, a trigger refused
// by the window it opened arms the next one, and a trailing plan whose demand
// drained meanwhile does nothing.
func TestSwapPlanGateRefusedHeartbeatArmsOneTrailingPlan(t *testing.T) {
	reg := New(testLogger())
	reg.loadModelSender = func(string, string) error { return nil }
	const cold = "swap-trailing-gate-cold-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: cold, SizeGB: 8, MinRAMGB: 16}})
	makeSchedulerProvider(t, reg, "warm-other", "swap-trailing-gate-other-model", 100)
	stub := installTrailingTimerStub(reg)
	if err := reg.Queue().Enqueue(swapTestQueued("swap-trailing-gate-req", cold)); err != nil {
		t.Fatal(err)
	}

	t0 := time.Now()
	now := t0
	reg.swapPlanGate.now = func() time.Time { return now }
	if !reg.triggerModelSwapsFromHeartbeat(t0) {
		t.Fatal("the trigger opening the window must plan")
	}
	if len(stub.fire) != 0 {
		t.Fatal("an admitted plan must not arm a trailing plan")
	}

	if reg.triggerModelSwapsFromHeartbeat(t0.Add(100 * time.Millisecond)) {
		t.Fatal("a trigger inside the window must be coalesced")
	}
	if reg.triggerModelSwapsFromHeartbeat(t0.Add(120 * time.Millisecond)) {
		t.Fatal("a trigger inside the window must be coalesced")
	}
	if len(stub.waits) != 1 {
		t.Fatalf("trailing plans armed = %d, want 1 for two refused triggers", len(stub.waits))
	}
	if want := modelSwapPlanInterval - 100*time.Millisecond; stub.waits[0] != want {
		t.Fatalf("trailing plan wait = %v, want %v (the rest of the window)", stub.waits[0], want)
	}
	if !reg.swapPlanGate.trailingArmed() {
		t.Fatal("gate must report the trailing plan armed")
	}
	if reg.swapPlanGate.planRuns() != 1 {
		t.Fatalf("plans before the trailing fire = %d, want 1", reg.swapPlanGate.planRuns())
	}

	now = t0.Add(modelSwapPlanInterval)
	stub.fire[0]()
	if reg.swapPlanGate.planRuns() != 2 {
		t.Fatalf("plans after the trailing fire = %d, want 2", reg.swapPlanGate.planRuns())
	}
	if reg.swapPlanGate.trailingArmed() {
		t.Fatal("the trailing plan must disarm when it fires")
	}

	// The trailing plan opened a new window; a trigger it refuses arms the next
	// trailing plan.
	last := reg.swapPlanGate.last
	if reg.triggerModelSwapsFromHeartbeat(last.Add(10 * time.Millisecond)) {
		t.Fatal("a trigger inside the trailing plan's window must be coalesced")
	}
	if len(stub.waits) != 2 || stub.waits[1] != modelSwapPlanInterval-10*time.Millisecond {
		t.Fatalf("trailing plans armed = %v, want a second one timed for the new window's end", stub.waits)
	}

	// Demand gone before it fires: nothing to plan.
	reg.Queue().Remove("swap-trailing-gate-req", cold)
	stub.fire[1]()
	if reg.swapPlanGate.planRuns() != 2 {
		t.Fatalf("trailing plan ran on an empty queue (%d plans)", reg.swapPlanGate.planRuns())
	}
	if reg.swapPlanGate.trailingArmed() {
		t.Fatal("a fired trailing plan must disarm even when it finds nothing to do")
	}
}

// TestHeartbeatBurstPlansSwapsOnce drives the real Heartbeat path: 50
// heartbeats from providers advertising a queued-but-unservable model, all
// inside one window, produce a single plan.
func TestHeartbeatBurstPlansSwapsOnce(t *testing.T) {
	reg := New(testLogger())
	reg.loadModelSender = func(string, string) error { return nil }
	const cold = "swap-burst-cold-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: cold, SizeGB: 8, MinRAMGB: 16}})
	var ids []string
	for i := 0; i < 5; i++ {
		id := fmt.Sprintf("crashed-%d", i)
		ids = append(ids, id)
		makeSchedulerProvider(t, reg, id, cold, 100)
		reg.Heartbeat(id, swapTestHeartbeat(cold, "crashed")) // unservable before the request queues
	}
	if err := reg.Queue().Enqueue(swapTestQueued("swap-burst-req", cold)); err != nil {
		t.Fatal(err)
	}
	// Open the window deterministically, then burst. The window (and the
	// trailing plan it may arm) is anchored at start so a trailing fire is
	// only ever observed with elapsed >= modelSwapPlanInterval.
	start := time.Now()
	if ok, _ := reg.swapPlanGate.claim(start); !ok {
		t.Fatal("precondition: gate claim")
	}
	before := reg.swapPlanGate.planRuns()
	for i := 0; i < 50; i++ {
		reg.Heartbeat(ids[i%len(ids)], swapTestHeartbeat(cold, "crashed"))
	}
	elapsed := time.Since(start)
	extra := reg.swapPlanGate.planRuns() - before
	if elapsed < modelSwapPlanInterval && extra != 0 {
		t.Fatalf("50 heartbeats in %v planned %d extra times, want 0 inside the window", elapsed, extra)
	}
	if extra > 1 {
		t.Fatalf("50 heartbeats planned %d extra times, want at most 1", extra)
	}
	if reg.Queue().QueueSize(cold) != 1 {
		t.Fatalf("crashed providers must not drain the request (queue size %d)", reg.Queue().QueueSize(cold))
	}
}

// TestHeartbeatRefusedByWindowStillPlansWithinInterval drives the real
// Heartbeat path and the real timer: a plan has just run (and found nothing
// to load), then a heartbeat inside the window reports the change that makes
// a provider loadable — its slot for the queued model is crashed, so the drain
// cannot place the request, and free_for_load_gb now covers a reload. The gate
// refuses that heartbeat; the trailing plan must send the load_model that,
// before it, waited for the next heartbeat (seconds away in a small fleet;
// master planned on every heartbeat).
func TestHeartbeatRefusedByWindowStillPlansWithinInterval(t *testing.T) {
	reg := New(testLogger())
	loads := make(chan string, 4)
	reg.loadModelSender = func(providerID, model string) error {
		loads <- providerID + "/" + model
		return nil
	}
	const model = "swap-trailing-hb-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 8, MinRAMGB: 16}})
	p := makeSchedulerProvider(t, reg, "p1", model, 100)
	// Crashed slot, no room to reload: the planner cannot pick it either.
	reg.Heartbeat(p.ID, swapTestCrashedHeartbeat(model, 1))
	if err := reg.Queue().Enqueue(swapTestQueued("swap-trailing-hb-req", model)); err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	if !reg.triggerModelSwapsFromHeartbeat(start) {
		t.Fatal("precondition: the plan opening the window must run")
	}
	select {
	case got := <-loads:
		t.Fatalf("planner sent load_model (%s) with 1 GB free_for_load", got)
	default:
	}

	// Inside the window the provider reports room to reload. The drain still
	// cannot place the request (slot_crashed) and the gate refuses the plan.
	reg.Heartbeat(p.ID, swapTestCrashedHeartbeat(model, 32))
	if time.Since(start) < modelSwapPlanInterval && reg.swapPlanGate.planRuns() != 1 {
		t.Fatalf("heartbeat inside the window planned synchronously (%d plans)", reg.swapPlanGate.planRuns())
	}
	select {
	case got := <-loads:
		if want := p.ID + "/" + model; got != want {
			t.Fatalf("trailing plan sent load_model %s, want %s", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("heartbeat refused by the window produced no load_model: the trailing plan did not run")
	}
	if reg.swapPlanGate.planRuns() != 2 {
		t.Fatalf("plans = %d, want 2 (the one opening the window and the trailing one)", reg.swapPlanGate.planRuns())
	}
	if reg.Queue().QueueSize(model) != 1 {
		t.Fatalf("crashed slot must not drain the request (queue size %d)", reg.Queue().QueueSize(model))
	}
}

// TestHeartbeatWarmReportStillDrainsQueuedRequest pins the semantics the
// coalescing must not touch: the per-heartbeat drain. A provider whose slot
// is crashed leaves the request queued; the heartbeat that reports the model
// running hands the request over immediately — with the swap planner gate
// held closed, so the drain (not the planner) is what delivered it — and the
// trailing plan the refused heartbeat armed then finds nothing to do.
func TestHeartbeatWarmReportStillDrainsQueuedRequest(t *testing.T) {
	reg := New(testLogger())
	reg.loadModelSender = func(string, string) error { return nil }
	const model = "swap-drain-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 8, MinRAMGB: 16}})
	p := makeSchedulerProvider(t, reg, "p1", model, 100)
	reg.Heartbeat(p.ID, swapTestHeartbeat(model, "crashed"))
	stub := installTrailingTimerStub(reg)

	req := swapTestQueued("swap-drain-req", model)
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatal(err)
	}
	if ok, _ := reg.swapPlanGate.claim(time.Now()); !ok {
		t.Fatal("precondition: gate claim")
	}
	runsBefore := reg.swapPlanGate.planRuns()

	reg.Heartbeat(p.ID, swapTestHeartbeat(model, "crashed"))
	select {
	case got := <-req.ResponseCh:
		t.Fatalf("crashed slot must not drain the request (got %v)", got)
	default:
	}
	if reg.Queue().QueueSize(model) != 1 {
		t.Fatal("request must remain queued while the slot is crashed")
	}
	if len(stub.fire) != 1 {
		t.Fatalf("refused heartbeat armed %d trailing plans, want 1", len(stub.fire))
	}

	reg.Heartbeat(p.ID, swapTestHeartbeat(model, "running"))
	select {
	case got := <-req.ResponseCh:
		if got == nil || got.ID != p.ID {
			t.Fatalf("drained to %v, want %s", got, p.ID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the heartbeat that reported the model running did not drain the queued request")
	}
	if reg.Queue().QueueSize(model) != 0 {
		t.Fatal("request must leave the queue once drained")
	}
	if reg.swapPlanGate.planRuns() != runsBefore {
		t.Fatalf("the planner ran %d times during the drain; the drain must not depend on it",
			reg.swapPlanGate.planRuns()-runsBefore)
	}
	// The trailing plan armed while the request waited finds the queue empty.
	stub.fire[0]()
	if reg.swapPlanGate.planRuns() != runsBefore {
		t.Fatal("trailing plan must not run once the drain has emptied the queue")
	}
}
