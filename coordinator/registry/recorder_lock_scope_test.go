package registry

import (
	"testing"
	"time"
)

// Read-first success recorders: RecordInferenceSuccess and
// ClearDispatchLoadCooldown run once per served request and almost never
// find state to delete, so they must not take Registry.mu for writing on the
// common path (each unnecessary Lock() is a full trip through the writer
// queue behind the in-flight reader batch). pendingModelLoadCount is per
// warm-pool tick, kept read-first for the same lock hygiene.

// exclusiveAcquisitions returns the number of Registry.mu write acquisitions
// so far in the current window (the T8-01 instrument, non-resetting).
func exclusiveAcquisitions(r *Registry) int64 {
	return r.LockWaitPeek().Count
}

func TestRecordInferenceSuccessReadFirst(t *testing.T) {
	r := New(testLogger())
	const provider, model, shape = "p-success", "m", "base"
	// No state: no write acquisition.
	before := exclusiveAcquisitions(r)
	r.RecordInferenceSuccess(provider, model, shape)
	if got := exclusiveAcquisitions(r); got != before {
		t.Fatalf("success with no strike state took %d write lock(s), want 0", got-before)
	}
	// Strikes present: the write path runs and clears them.
	r.RecordInferenceError(provider, model, 500, shape)
	r.RecordInferenceError(provider, model, 500, shape)
	if !r.InferenceErrorCooldownActive(provider, model, shape) {
		t.Fatal("fixture: cooldown should be active after two strikes")
	}
	before = exclusiveAcquisitions(r)
	r.RecordInferenceSuccess(provider, model, shape)
	if got := exclusiveAcquisitions(r); got != before+1 {
		t.Fatalf("success with state took %d write lock(s), want 1", got-before)
	}
	if r.InferenceErrorCooldownActive(provider, model, shape) {
		t.Fatal("success must clear the triple's cool-down")
	}
	r.mu.RLock()
	_, strikes := r.inferenceErrorStrikes[inferenceErrorKey{ProviderID: provider, ModelID: model, Shape: shape}]
	r.mu.RUnlock()
	if strikes {
		t.Fatal("success must clear the triple's strikes")
	}
}

func TestClearDispatchLoadCooldownReadFirst(t *testing.T) {
	r := New(testLogger())
	const provider, model = "p-load", "m"
	before := exclusiveAcquisitions(r)
	r.ClearDispatchLoadCooldown(provider, model)
	if got := exclusiveAcquisitions(r); got != before {
		t.Fatalf("clear with no cooldown took %d write lock(s), want 0", got-before)
	}
	r.RecordDispatchLoadFailure(provider, model)
	r.mu.RLock()
	cooling := r.dispatchLoadCooldownActiveLocked(provider, model, time.Now())
	r.mu.RUnlock()
	if !cooling {
		t.Fatal("fixture: dispatch-load cooldown should be active")
	}
	before = exclusiveAcquisitions(r)
	r.ClearDispatchLoadCooldown(provider, model)
	if got := exclusiveAcquisitions(r); got != before+1 {
		t.Fatalf("clear with a cooldown took %d write lock(s), want 1", got-before)
	}
	r.mu.RLock()
	cooling = r.dispatchLoadCooldownActiveLocked(provider, model, time.Now())
	r.mu.RUnlock()
	if cooling {
		t.Fatal("clear must remove the pair's cooldown")
	}
}

func TestPendingModelLoadCountReadFirst(t *testing.T) {
	r := New(testLogger())
	now := time.Now()
	r.mu.Lock()
	r.pendingModelLoads[modelLoadKey{ProviderID: "a", ModelID: "m"}] = now.Add(time.Minute)
	r.pendingModelLoads[modelLoadKey{ProviderID: "b", ModelID: "m"}] = now.Add(time.Minute)
	r.mu.Unlock()
	before := exclusiveAcquisitions(r)
	if n := r.pendingModelLoadCount(now); n != 2 {
		t.Fatalf("count=%d, want 2", n)
	}
	if got := exclusiveAcquisitions(r); got != before {
		t.Fatalf("count with no expired entry took %d write lock(s), want 0", got-before)
	}
	// An expired entry is reaped under the write lock, exactly once.
	r.mu.Lock()
	r.pendingModelLoads[modelLoadKey{ProviderID: "c", ModelID: "m"}] = now.Add(-time.Second)
	r.mu.Unlock()
	before = exclusiveAcquisitions(r)
	if n := r.pendingModelLoadCount(now); n != 2 {
		t.Fatalf("count=%d, want 2 (expired entry not counted)", n)
	}
	if got := exclusiveAcquisitions(r); got != before+1 {
		t.Fatalf("count with an expired entry took %d write lock(s), want 1", got-before)
	}
	r.mu.RLock()
	_, stillThere := r.pendingModelLoads[modelLoadKey{ProviderID: "c", ModelID: "m"}]
	r.mu.RUnlock()
	if stillThere {
		t.Fatal("expired entry must be reaped")
	}
}

// TestSuccessRecordersDoNotQueueBehindParkedScan is the lock-scope test: with
// a reservation scan parked under r.mu.RLock, each read-first recorder with
// no state returns while the scan is still parked (the shared lock admits
// them alongside the reader) and never queues as a writer. Before the change
// each blocked on r.mu.Lock until the scan released.
func TestSuccessRecordersDoNotQueueBehindParkedScan(t *testing.T) {
	reg := New(testLogger())
	model := "lock-scope-model"
	p := planTestProvider(t, reg, "scope-p", model, 0)

	parked := make(chan struct{})
	release := make(chan struct{})
	reg.reservationAfterScan = func(string) {
		close(parked)
		<-release
	}
	scanDone := make(chan struct{})
	go func() {
		defer close(scanDone)
		pr := planTestRequest("scope-req", 100, 100)
		pr.Model = model
		if got, _ := reg.ReserveProviderEx(model, pr); got != nil {
			got.RemovePending(pr.RequestID)
		}
	}()
	<-parked

	recorders := map[string]func(){
		"RecordInferenceSuccess":    func() { reg.RecordInferenceSuccess(p.ID, model, "base") },
		"ClearDispatchLoadCooldown": func() { reg.ClearDispatchLoadCooldown(p.ID, model) },
		"pendingModelLoadCount":     func() { reg.pendingModelLoadCount(time.Now()) },
	}
	for name, call := range recorders {
		done := make(chan struct{})
		go func() {
			defer close(done)
			call()
		}()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			close(release)
			<-scanDone
			t.Fatalf("%s blocked behind the parked scan (queued as a writer)", name)
		}
	}
	if w := reg.LockWaitPeek().WritersWaiting; w != 0 {
		t.Fatalf("writers waiting = %d while the scan is parked, want 0", w)
	}
	close(release)
	<-scanDone
}
