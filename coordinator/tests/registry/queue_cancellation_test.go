package registry_test

import (
	"context"
	"errors"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestQueueExpiredLiveWaiterStillSignalsTimeout(t *testing.T) {
	queue := production.NewRequestQueue(1, time.Second)
	req := &production.QueuedRequest{RequestID: "expired", Model: drainTestModel}
	if err := queue.Enqueue(req); err != nil {
		t.Fatal(err)
	}
	req.EnqueuedAt = time.Now().Add(-time.Hour)
	if got := queue.PopNextFresh(drainTestModel); got != nil {
		t.Fatal("expired live waiter was returned")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := queue.WaitForProviderContext(ctx, req); !errors.Is(err, production.ErrQueueTimeout) {
		t.Fatalf("expired waiter result=%v, want ErrQueueTimeout", err)
	}
	if queue.HasQueued() {
		t.Fatal("expired waiter retained demand")
	}
}

// A waiter closes Done before Remove acquires the queue lock. Model that
// terminal-but-not-yet-removed state directly, then exercise each queue mutation
// that can encounter it. Terminal cause and notification must remain unchanged.
func TestQueueTerminalWaitersAreDroppedAtMutationBoundaries(t *testing.T) {
	for _, sweep := range []bool{false, true} {
		name := "pop"
		if sweep {
			name = "sweep"
		}
		t.Run(name, func(t *testing.T) {
			queue := production.NewRequestQueue(2, 30*time.Second)
			terminal := &production.QueuedRequest{RequestID: "terminal", Model: drainTestModel}
			live := &production.QueuedRequest{RequestID: "live", Model: drainTestModel}
			for _, req := range []*production.QueuedRequest{terminal, live} {
				if err := queue.Enqueue(req); err != nil {
					t.Fatal(err)
				}
			}
			terminal.FailureReason = context.Canceled
			terminal.Cancel()
			if sweep {
				if models := queue.QueuedModels(); len(models) != 1 || models[0] != drainTestModel {
					t.Fatalf("sweep discarded live demand: models=%v", models)
				}
				fresh := &production.QueuedRequest{RequestID: "fresh", Model: drainTestModel}
				if err := queue.Enqueue(fresh); err != nil {
					t.Fatalf("terminal entry retained queue capacity: %v", err)
				}
			}
			if got := queue.PopNextFresh(drainTestModel); got != live {
				t.Fatalf("next waiter=%v, want live neighbor", got)
			}
			if got := queue.PopNextFresh(drainTestModel); sweep {
				if got == nil || got.RequestID != "fresh" {
					t.Fatalf("sweep changed live FIFO order: next=%v", got)
				}
			} else if got != nil {
				t.Fatalf("pop left an unexpected waiter: %v", got)
			}
			if terminal.FailureReason != context.Canceled {
				t.Fatalf("queue changed terminal cause: %v", terminal.FailureReason)
			}
			select {
			case <-terminal.ResponseCh:
				t.Fatal("queue sent an additional terminal notification")
			default:
			}
		})
	}
}

// The scheduler holds this waiter outside the queue while deciding whether it
// can run. Cancellation's Remove therefore cannot see it; the completed waiter
// must not become demand again when the scheduler requeues its skipped list.
func TestDrainCancelledSkippedWaiterDoesNotReturnToQueue(t *testing.T) {
	reg := newDrainRegistry()
	provider := drainTestProvider(t, reg, "saturated", 1000, 1000)
	reg.SetQueue(production.NewRequestQueue(1, 30*time.Second))
	drainTestClock(reg)
	req := drainTestEnqueue(t, reg, drainTestPending("cancelled", 800, 1024))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	waitResult := make(chan error, 1)
	go func() {
		_, err := reg.Queue().WaitForProviderContext(ctx, req)
		waitResult <- err
	}()

	pops := 0
	reg.claims.beforePop = func(string) {
		pops++
		if pops != 2 {
			return
		}
		if depth := reg.Queue().QueueSize(drainTestModel); depth != 0 {
			t.Fatalf("waiter was not held outside queue: depth=%d", depth)
		}
		cancel()
		select {
		case err := <-waitResult:
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("waiter result=%v, want context.Canceled", err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("canceled waiter did not finish while held by scheduler")
		}
	}
	reg.SetProviderIdle(provider.ID)
	reg.claims.beforePop = nil
	if pops != 2 {
		t.Fatalf("scheduler pops=%d, want waiter then empty queue", pops)
	}
	if depth := reg.Queue().QueueSize(drainTestModel); depth != 0 {
		t.Errorf("canceled skipped waiter returned to queue: depth=%d", depth)
	}
	if reg.Queue().HasQueued() || len(reg.Queue().QueuedModels()) != 0 {
		t.Error("canceled skipped waiter remains visible as queued demand")
	}
	if count := provider.PendingCount(); count != 0 {
		t.Errorf("canceled waiter reserved provider capacity: pending=%d", count)
	}
	fresh := &production.QueuedRequest{RequestID: "fresh", Model: drainTestModel}
	if err := reg.Queue().Enqueue(fresh); err != nil {
		t.Errorf("canceled waiter occupies the only queue slot: fresh enqueue=%v", err)
	}
}

func TestDrainLiveSkippedWaitersRetainFIFOAndReleaseReservations(t *testing.T) {
	reg := newDrainRegistry()
	provider := drainTestProvider(t, reg, "saturated", 1000, 1000)
	reg.SetQueue(production.NewRequestQueue(2, 30*time.Second))
	drainTestClock(reg)
	first := drainTestEnqueue(t, reg, drainTestPending("first", 800, 1024))
	second := drainTestEnqueue(t, reg, drainTestPending("second", 800, 1024))
	reg.SetProviderIdle(provider.ID)
	if order := drainTestQueueOrder(reg); len(order) != 2 || order[0] != "first" || order[1] != "second" {
		t.Fatalf("live skipped queue order=%v, want [first second]", order)
	}
	drainTestAssertQueued(t, first)
	drainTestAssertQueued(t, second)

	drainTestSetBudget(provider, 0, 32_768)
	reg.SetProviderIdle(provider.ID)
	for _, req := range []*production.QueuedRequest{first, second} {
		if got := drainTestAwait(t, reg, req); got != provider {
			t.Fatalf("live waiter %s assigned to unexpected provider", req.RequestID)
		}
	}
	if count := provider.PendingCount(); count != 2 {
		t.Fatalf("live assignments pending=%d, want 2", count)
	}
	for _, req := range []*production.QueuedRequest{first, second} {
		if got := provider.RemovePending(req.RequestID); got != req.Pending {
			t.Fatalf("live cleanup %s did not own its pending request", req.RequestID)
		}
		if got := provider.RemovePending(req.RequestID); got != nil {
			t.Fatalf("live cleanup %s removed a second reservation", req.RequestID)
		}
	}
	reg.SetProviderIdle(provider.ID)
	if provider.PendingCount() != 0 || reg.Queue().HasQueued() {
		t.Fatal("live control left pending work or queued demand after cleanup")
	}
	provider.Mu().Lock()
	status := provider.Status
	provider.Mu().Unlock()
	if status != production.StatusOnline {
		t.Fatalf("provider status after cleanup=%s, want online", status)
	}
}

func TestQueueCancellationBeforeAndAfterSkippedPass(t *testing.T) {
	for _, afterPass := range []bool{false, true} {
		name := "before_pop"
		if afterPass {
			name = "after_requeue"
		}
		t.Run(name, func(t *testing.T) {
			reg := newDrainRegistry()
			provider := drainTestProvider(t, reg, "saturated", 1000, 1000)
			reg.SetQueue(production.NewRequestQueue(1, 30*time.Second))
			drainTestClock(reg)
			req := drainTestEnqueue(t, reg, drainTestPending("cancelled", 800, 1024))
			if afterPass {
				reg.SetProviderIdle(provider.ID)
				if depth := reg.Queue().QueueSize(drainTestModel); depth != 1 {
					t.Fatalf("live waiter was not requeued: depth=%d", depth)
				}
			}
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			if _, err := reg.Queue().WaitForProviderContext(ctx, req); !errors.Is(err, context.Canceled) {
				t.Fatalf("waiter result=%v, want context.Canceled", err)
			}
			reg.SetProviderIdle(provider.ID)
			if reg.Queue().HasQueued() || provider.PendingCount() != 0 {
				t.Fatal("cancellation left queued demand or a provider reservation")
			}
		})
	}
}
