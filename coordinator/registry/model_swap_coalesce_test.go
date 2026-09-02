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

// TestSwapPlanGateCoalescesBurstAndReopensAfterWindow pins the gate itself
// with an injected clock: 50 heartbeat triggers inside one window plan once,
// the first trigger after the window plans again, and an empty queue never
// plans at all.
func TestSwapPlanGateCoalescesBurstAndReopensAfterWindow(t *testing.T) {
	reg := New(testLogger())
	reg.loadModelSender = func(string, string) error { return nil }
	const cold = "swap-gate-cold-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: cold, SizeGB: 8, MinRAMGB: 16}})
	makeSchedulerProvider(t, reg, "warm-other", "swap-gate-other-model", 100)

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
	// Open the window deterministically, then burst.
	if !reg.swapPlanGate.claim(time.Now()) {
		t.Fatal("precondition: gate claim")
	}
	before := reg.swapPlanGate.planRuns()
	start := time.Now()
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

// TestHeartbeatWarmReportStillDrainsQueuedRequest pins the semantics the
// coalescing must not touch: the per-heartbeat drain. A provider whose slot
// is crashed leaves the request queued; the heartbeat that reports the model
// running hands the request over immediately — with the swap planner gate
// held closed, so the drain (not the planner) is what delivered it.
func TestHeartbeatWarmReportStillDrainsQueuedRequest(t *testing.T) {
	reg := New(testLogger())
	reg.loadModelSender = func(string, string) error { return nil }
	const model = "swap-drain-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 8, MinRAMGB: 16}})
	p := makeSchedulerProvider(t, reg, "p1", model, 100)
	reg.Heartbeat(p.ID, swapTestHeartbeat(model, "crashed"))

	req := swapTestQueued("swap-drain-req", model)
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatal(err)
	}
	if !reg.swapPlanGate.claim(time.Now()) {
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
}
