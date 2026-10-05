package promptcontract_test

import (
	"context"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

const (
	// A Status call returns at once when the controller's lock is free and
	// cannot return while a caller holds it; this is how long one is given.
	preloadLockHeldWindow = 25 * time.Millisecond
	// A free lock is never this slow to take.
	preloadLockFreeTimeout = 2 * time.Second
)

// preloadLockProbe observes the controller's serializing lock from outside,
// through Status: the one method that takes that lock and no other.
type preloadLockProbe struct {
	controller *preload.PreloadController
	calls      sync.WaitGroup
}

func newPreloadLockProbe(t *testing.T, controller *preload.PreloadController) *preloadLockProbe {
	t.Helper()
	probe := &preloadLockProbe{controller: controller}
	t.Cleanup(probe.calls.Wait)
	return probe
}

// free reports whether Status returned within wait. A call still blocked then
// returns as soon as the holder releases the lock.
func (p *preloadLockProbe) free(wait time.Duration) bool {
	done := make(chan struct{})
	p.calls.Add(1)
	go func() {
		defer p.calls.Done()
		defer close(done)
		p.controller.Status()
	}()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-done:
		return true
	case <-timer.C:
		return false
	}
}

// activeControllerClock takes manual control of the controller's injected
// policy clock. Every sample must find the serializing lock held.
func activeControllerClock(t *testing.T, f *readinessControllerFixture) *atomic.Int64 {
	t.Helper()
	now := new(atomic.Int64)
	probe := newPreloadLockProbe(t, f.controller)
	clock := func() time.Duration {
		if probe.free(preloadLockHeldWindow) {
			t.Error("policy sampled its monotonic clock outside the serializing lock")
		}
		return time.Duration(now.Load())
	}
	f.policyClock.Store(&clock)
	return now
}

func activeControllerSource(t *testing.T, c *preload.PreloadController, allowed *atomic.Bool) {
	t.Helper()
	probe := newPreloadLockProbe(t, c)
	if !c.SetSelectionSource(func(verified []preload.VerifiedPreloadArtifact, _ bool) ([]preload.PreloadDemandIdentity, []string) {
		if !probe.free(preloadLockFreeTimeout) {
			t.Error("Registry projection callback ran under controller lock")
		}
		if !allowed.Load() {
			return nil, nil
		}
		return slices.Clone(verified), nil // Synthetic authenticated-policy projection only.
	}) {
		t.Fatal("selection source did not install before Start")
	}
}

func TestPreloadControllerOverflowRequiresDemandAndRotatesNinth(t *testing.T) {
	var maxBatch atomic.Int64
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport {
		for previous := maxBatch.Load(); int64(len(ids)) > previous; previous = maxBatch.Load() {
			if maxBatch.CompareAndSwap(previous, int64(len(ids))) {
				break
			}
		}
		return readinessReport(ids, "")
	})
	var allowed atomic.Bool
	allowed.Store(true)
	activeControllerSource(t, f.controller, &allowed)
	now := activeControllerClock(t, f)
	ids := make([]string, 9)
	for i := range ids {
		ids[i] = activeSetContract(i + 1)
	}
	f.verified(ids...)
	f.controller.Reconcile(context.Background())
	if f.preloads.Load() != 0 || f.controller.Status().LastError != "capacity_deferred" || f.controller.Status().Failures != 0 {
		t.Fatal("no-demand overflow chose an arbitrary prefix or counted a failed runtime load")
	}
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	for _, identity := range verified[:8] {
		if !f.controller.NoteDemand(identity) {
			t.Fatal("current eligible demand was refused")
		}
	}
	f.controller.Reconcile(context.Background())
	if f.preloads.Load() != 1 || f.controller.Status().ContractCount != 8 || maxBatch.Load() != 8 {
		t.Fatalf("bounded first demand batch: %+v", f.controller.Status())
	}
	if f.controller.ReadyFor(ids[8]) || !f.controller.NoteDemand(verified[8]) {
		t.Fatal("ninth was already loaded or its legitimate interest was lost")
	}
	now.Store(int64(29 * time.Second))
	for range 3 {
		f.controller.NoteDemand(verified[0])
		f.controller.Reconcile(context.Background())
	}
	if f.preloads.Load() != 1 || f.controller.ReadyFor(ids[8]) {
		t.Fatal("residence was bypassed")
	}
	now.Store(int64(30 * time.Second))
	f.controller.Reconcile(context.Background())
	state := f.controller.PlanningState(verified[8])
	if !state.Acknowledged || !state.Participating || f.controller.ReadyFor(ids[0]) ||
		f.preloads.Load() != 2 || maxBatch.Load() > 8 || f.controller.Status().ContractCount != 8 {
		t.Fatal("oldest continuously waiting ninth contract did not replace one incumbent within C")
	}
	if f.provisioner.Snapshot().Counts.Ready != 9 || len(f.provisioner.Snapshot().ContractIDs) != 9 {
		t.Fatal("selection pruned authoritative verified membership")
	}
}

func TestPreloadCompletedAcknowledgementSurvivesOnlyAdmissibilityDrift(t *testing.T) {
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport { return readinessReport(ids, "") })
	a := strings.Repeat("a", 64)
	f.verified(a)
	var allowed atomic.Bool
	allowed.Store(true)
	activeControllerSource(t, f.controller, &allowed)
	activeControllerClock(t, f)
	f.controller.Reconcile(context.Background())
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	identity := verified[0]
	if state := f.controller.PlanningState(identity); !state.Acknowledged || !state.Participating {
		t.Fatal("positive acknowledgement missing")
	}
	allowed.Store(false)
	f.controller.Reconcile(context.Background()) // Force a real controller poll while revoked.
	if state := f.controller.PlanningState(identity); !state.Acknowledged || state.Participating {
		t.Fatal("revocation lost native diagnostic fact or retained routing participation")
	}
	if !f.controller.ReadyFor(a) || f.controller.NoteDemand(identity) || f.preloads.Load() != 1 {
		t.Fatal("revocation triggered a fake reload or authorized demand")
	}
	allowed.Store(true)
	f.controller.Reconcile(context.Background()) // No new preload may erase the completed fact.
	if state := f.controller.PlanningState(identity); !state.Acknowledged || !state.Participating {
		t.Fatal("revalidated restoration did not recover")
	}
	if f.preloads.Load() != 1 || f.controller.Status().Runs != 1 || f.controller.Status().Warm != 1 {
		t.Fatal("admissibility drift manufactured new runtime acknowledgement counters")
	}
	f.controller.Close()
	if f.controller.ReadyFor(a) || f.controller.PlanningState(identity).Acknowledged {
		t.Fatal("Close retained acknowledgement")
	}
}

func TestPreloadStandaloneAcknowledgementIsNotRegistryAuthorization(t *testing.T) {
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport { return readinessReport(ids, "") })
	f.verified(activeSetContract(1))
	f.controller.Reconcile(context.Background())
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	state := f.controller.PlanningState(verified[0])
	if !f.controller.ReadyFor(verified[0].PromptContractID) || !state.Acknowledged || state.Participating || f.controller.NoteDemand(verified[0]) {
		t.Fatal("standalone tokenizer readiness became missing-callback authorization")
	}
}

func TestPreloadInflightAdmissibilityABANeverBecomesCompletedAcknowledgement(t *testing.T) {
	entered, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var once sync.Once
	open := func() { once.Do(func() { close(release) }) }
	f := newReadinessControllerFixture(t, func(ctx context.Context, call int64, ids []string) sidecar.PreloadReport {
		if call == 1 {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
			}
		}
		return readinessReport(ids, "")
	})
	t.Cleanup(open)
	f.verified(activeSetContract(1))
	var allowed atomic.Bool
	allowed.Store(true)
	activeControllerSource(t, f.controller, &allowed)
	activeControllerClock(t, f)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { defer close(done); f.controller.Reconcile(ctx) }()
	t.Cleanup(func() {
		cancel()
		open()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("owned preload goroutine remained after cleanup")
		}
	})
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("preload did not enter transport")
	}
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	allowed.Store(false)
	f.controller.PlanningState(verified[0])
	allowed.Store(true)
	f.controller.PlanningState(verified[0])
	f.controller.Reconcile(ctx)
	if f.preloads.Load() != 1 {
		t.Fatal("revocation created an overlapping operation")
	}
	open()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("old operation did not drain")
	}
	if f.controller.ReadyFor(verified[0].PromptContractID) || f.controller.Status().Runs != 0 || f.controller.Status().Warm != 0 {
		t.Fatal("in-flight K ABA was reclassified as a completed native acknowledgement")
	}
	f.controller.Reconcile(ctx)
	if state := f.controller.PlanningState(verified[0]); !state.Acknowledged || !state.Participating || f.preloads.Load() != 2 {
		t.Fatal("fresh independent current-key acknowledgement did not recover")
	}
}
