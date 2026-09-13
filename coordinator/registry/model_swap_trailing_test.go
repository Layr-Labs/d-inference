package registry

import (
	"sync"
	"testing"
	"time"
)

// A delayed old timer must not lose a state change suppressed by a newer
// window. The first two plans see insufficient reload memory; only the final
// heartbeat supplies enough, and no further heartbeat follows it.
func TestDelayedTrailingPlanPreservesNewWindowHeartbeat(t *testing.T) {
	reg := New(testLogger())
	loads := make(chan string, 4)
	reg.loadModelSender = func(providerID, model string) error {
		loads <- providerID + "/" + model
		return nil
	}
	const model = "swap-delayed-trailing-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 8, MinRAMGB: 16}})
	p := makeSchedulerProvider(t, reg, "p1", model, 100)
	reg.Heartbeat(p.ID, swapTestCrashedHeartbeat(model, 1))
	if err := reg.Queue().Enqueue(swapTestQueued("swap-delayed-trailing-request", model)); err != nil {
		t.Fatal(err)
	}
	stub := installTrailingTimerStub(reg)
	t0 := time.Now()
	now := t0
	reg.swapPlanGate.now = func() time.Time { return now }
	reg.triggerModelSwapsFromHeartbeat(t0)
	reg.triggerModelSwapsFromHeartbeat(t0.Add(100 * time.Millisecond))
	if len(stub.fire) != 1 {
		t.Fatal("suppressed heartbeat did not arm the old timer")
	}
	// Its timer is delayed; another heartbeat plans after the window opens.
	newWindow := t0.Add(modelSwapPlanInterval + 10*time.Millisecond)
	if !reg.triggerModelSwapsFromHeartbeat(newWindow) {
		t.Fatal("new heartbeat did not open a new planning window")
	}
	select {
	case got := <-loads:
		t.Fatalf("planned a reload with insufficient memory: %s", got)
	default:
	}
	// Simulate the heartbeat's state mutation and planner notification while
	// the old timer is still armed. A crashed slot cannot drain this request.
	p.mu.Lock()
	freeForLoadGB := 32.0
	p.BackendCapacity.FreeForLoadGB = &freeForLoadGB
	p.mu.Unlock()
	reg.triggerModelSwapsFromHeartbeat(newWindow.Add(10 * time.Millisecond))
	now = newWindow.Add(20 * time.Millisecond)
	stub.fire[0]()
	if len(stub.fire) != 2 || stub.waits[1] != modelSwapPlanInterval-20*time.Millisecond {
		t.Fatalf("old timer lost the new window's heartbeat: waits %v", stub.waits)
	}
	now = newWindow.Add(modelSwapPlanInterval)
	stub.fire[1]()
	select {
	case got := <-loads:
		if want := p.ID + "/" + model; got != want {
			t.Fatalf("load = %s, want %s", got, want)
		}
	default:
		t.Fatal("no reload after the delayed timer's follow-up")
	}
	if reg.swapPlanGate.planRuns() != 3 || reg.swapPlanGate.trailingArmed() {
		t.Fatal("trailing callback did not finish the third plan")
	}
}

// Hold an actual warm queue drain past the swap window. The remaining cold
// demand must trigger its reload as soon as Heartbeat finishes that drain,
// rather than scheduling a second delay from the stale heartbeat timestamp.
func TestHeartbeatSwapPlanClaimsAfterSlowQueueDrain(t *testing.T) {
	reg := New(testLogger())
	const cold, warm = "swap-post-drain-cold", "swap-post-drain-warm"
	reg.SetModelCatalog([]CatalogEntry{
		{ID: cold, SizeGB: 8, MinRAMGB: 16}, {ID: warm, SizeGB: 8, MinRAMGB: 16},
	})
	coldProvider := makeSchedulerProvider(t, reg, "post-drain-cold", cold, 100)
	warmProvider := makeSchedulerProvider(t, reg, "post-drain-warm", warm, 100)
	reg.Heartbeat(coldProvider.ID, swapTestCrashedHeartbeat(cold, 32))
	loads := make(chan string, 4)
	reg.loadModelSender = func(providerID, model string) error {
		loads <- providerID + "/" + model
		return nil
	}
	stub := installTrailingTimerStub(reg)
	for _, req := range []*QueuedRequest{swapTestQueued("post-drain-cold-request", cold), swapTestQueued("post-drain-warm-request", warm)} {
		if err := reg.Queue().Enqueue(req); err != nil {
			t.Fatal(err)
		}
	}
	draining, release := make(chan struct{}), make(chan struct{})
	releaseDrain := sync.OnceFunc(func() { close(release) })
	defer releaseDrain()
	reg.reservationAfterScan = func(model string) {
		if model == warm {
			close(draining)
			<-release
		}
	}
	done := make(chan struct{})
	go func() {
		reg.Heartbeat(warmProvider.ID, swapTestHeartbeat(warm, "running"))
		close(done)
	}()
	select {
	case <-draining:
	case <-time.After(2 * time.Second):
		t.Fatal("heartbeat did not enter the queued warm request's drain")
	}
	warmProvider.mu.Lock()
	heartbeatAt := warmProvider.LastHeartbeat
	warmProvider.mu.Unlock()
	if ok, _ := reg.swapPlanGate.claim(heartbeatAt); !ok {
		t.Fatal("precondition: another plan opens a window at the heartbeat timestamp")
	}
	if remaining := time.Until(heartbeatAt.Add(modelSwapPlanInterval + time.Millisecond)); remaining > 0 {
		time.Sleep(remaining)
	}
	releaseDrain()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("heartbeat did not finish after releasing the drain")
	}
	if len(stub.fire) != 0 {
		t.Fatal("heartbeat added a trailing delay although the planning window already elapsed")
	}
	select {
	case got := <-loads:
		if want := coldProvider.ID + "/" + cold; got != want {
			t.Fatalf("load = %s, want %s", got, want)
		}
	default:
		t.Fatal("elapsed planning window did not immediately reload the queued cold model")
	}
}
