package promptcontract

import (
	"context"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestPreloadPartialBackoffSurvivesAdmissibilityOnlyDrift(t *testing.T) {
	a, b, extra := activeSetContract(1), activeSetContract(2), activeSetContract(3)
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) PreloadReport { return readinessReport(ids, b) })
	f.verified(a, b)
	var allowed atomic.Bool
	allowed.Store(true)
	activeControllerSource(t, f.controller, &allowed)
	now := activeControllerClock(t, f.controller)
	f.controller.reconcile(context.Background())
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	f.controller.mu.RLock()
	deadline, backoff := f.controller.selection.batchRetryAt, f.controller.failureBackoff
	f.controller.mu.RUnlock()
	if deadline != time.Hour || backoff != time.Hour || !f.controller.ReadyFor(a) {
		t.Fatal("partial/backoff control missing")
	}
	now.Store(int64(time.Second))
	for _, enabled := range []bool{false, true, false, true} {
		allowed.Store(enabled)
		f.controller.reconcile(context.Background()) // Forced poll must not withdraw A or reset the clock.
		state := f.controller.PlanningState(verified[0])
		f.controller.mu.RLock()
		gotDeadline, gotBackoff := f.controller.selection.batchRetryAt, f.controller.failureBackoff
		f.controller.mu.RUnlock()
		if !state.Acknowledged || state.Participating != enabled || f.preloads.Load() != 1 ||
			gotDeadline != deadline || gotBackoff != backoff || f.controller.Status().LastError != "preload_failed" {
			t.Fatal("admissibility-only drift reset partial failure residence/backoff or native acknowledgement")
		}
	}
	f.verified(a, b, extra)
	f.controller.reconcile(context.Background())
	if f.preloads.Load() != 2 || !f.controller.ReadyFor(a) || !f.controller.ReadyFor(extra) || f.controller.ReadyFor(b) {
		t.Fatal("retaining the old retry deadline blocked genuinely new verified membership")
	}
}

// A blocked first projection owns capture->apply, not c.mu or transport. The
// second worker is deliberately started while it is held. An old implementation
// lets that worker complete first, then regresses the already-observed state.
func TestPreloadCaptureApplyCannotRegressNewerObservedAuthority(t *testing.T) {
	for _, change := range []string{"catalog", "admissibility"} {
		t.Run(change, func(t *testing.T) {
			a, b := activeSetContract(1), activeSetContract(2)
			f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) PreloadReport { return readinessReport(ids, "") })
			f.verified(a)
			var allowed, block atomic.Bool
			allowed.Store(true)
			entered, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			open := func() { once.Do(func() { close(release) }) }
			if !f.controller.SetSelectionSource(func(v []VerifiedPreloadArtifact, _ bool) ([]PreloadDemandIdentity, []string) {
				captured := allowed.Load()
				if block.CompareAndSwap(true, false) {
					close(entered)
					<-release
				}
				if captured {
					return slices.Clone(v), nil
				}
				return nil, nil
			}) {
				t.Fatal("source installation failed")
			}
			activeControllerClock(t, f.controller)
			f.controller.reconcile(context.Background())
			_, verified := f.provisioner.VerifiedPreloadArtifacts()
			block.Store(true)
			oldDone, newDone, newStarted := make(chan struct{}), make(chan struct{}), make(chan struct{})
			go func() { defer close(oldDone); f.controller.PlanningState(verified[0]) }()
			t.Cleanup(func() {
				open()
				for _, done := range []chan struct{}{oldDone, newDone} {
					select {
					case <-done:
					case <-time.After(5 * time.Second):
						t.Error("owned capture caller failed to drain")
					}
				}
			})
			select {
			case <-entered:
			case <-time.After(5 * time.Second):
				t.Fatal("first captured authority did not reach barrier")
			}
			if change == "catalog" {
				f.provisioner.mu.Lock()
				f.provisioner.generation++
				f.provisioner.mu.Unlock()
				f.verified(b)
			} else {
				allowed.Store(false)
			}
			go func() {
				defer close(newDone)
				close(newStarted)
				if change == "catalog" {
					f.controller.reconcile(context.Background())
				} else {
					f.controller.PlanningState(verified[0])
				}
			}()
			<-newStarted
			select {
			case <-newDone:
				t.Error("newer authority overtook a captured-but-unapplied predecessor")
			case <-time.After(100 * time.Millisecond):
			}
			open()
			for _, done := range []chan struct{}{oldDone, newDone} {
				select {
				case <-done:
				case <-time.After(5 * time.Second):
					t.Fatal("capture/apply callers did not drain")
				}
			}
			f.controller.mu.RLock()
			key, status := f.controller.selection.snapshot(), f.controller.status
			f.controller.mu.RUnlock()
			if change == "catalog" {
				if key.CatalogGeneration != 2 || len(key.Desired) != 1 || key.Desired[0] != b || !status.Ready || status.ContractCount != 1 {
					t.Fatal("late old capture erased the newer native acknowledgement")
				}
			} else if len(key.Admissible) != 0 {
				t.Fatal("late old capture reopened an already-observed revocation")
			}
		})
	}
}

func TestPreloadAdvisoryRefreshIsNotOnRequestPathOrAuthority(t *testing.T) {
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) PreloadReport { return readinessReport(ids, "") })
	f.verified(activeSetContract(1))
	var allowed atomic.Bool
	var refreshes atomic.Int64
	allowed.Store(true)
	if !f.controller.SetSelectionSource(func(v []VerifiedPreloadArtifact, refresh bool) ([]PreloadDemandIdentity, []string) {
		var public []string
		if refresh {
			refreshes.Add(1)
			public = []string{v[0].ModelID}
		}
		if !allowed.Load() {
			return nil, public
		}
		return slices.Clone(v), public
	}) {
		t.Fatal("source installation failed")
	}
	activeControllerClock(t, f.controller)
	f.controller.reconcile(context.Background())
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	if refreshes.Load() != 1 {
		t.Fatal("background reconcile did not refresh advisory visibility once")
	}
	for range 5 {
		f.controller.NoteDemand(verified[0])
		f.controller.ReadyFor(verified[0].PromptContractID)
		f.controller.PlanningState(verified[0])
	}
	if refreshes.Load() != 1 {
		t.Fatal("request path requested a whole-fleet availability scan")
	}
	allowed.Store(false) // Cached public visibility is intentionally still positive.
	if state := f.controller.PlanningState(verified[0]); !state.Acknowledged || state.Participating {
		t.Fatal("stale advisory visibility authorized current revoked eligibility")
	}
	f.provisioner.mu.Lock()
	f.provisioner.generation++
	f.provisioner.mu.Unlock()
	f.verified(activeSetContract(2))
	f.controller.ReadyFor(activeSetContract(2))
	f.controller.captureMu.Lock()
	retained := len(f.controller.publicAvailable)
	f.controller.captureMu.Unlock()
	if retained != 0 || refreshes.Load() != 1 {
		t.Fatal("new verified identity retained stale advisory data or scanned on request")
	}
}
