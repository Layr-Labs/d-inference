package promptcontract_test

import (
	"context"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func TestPreloadPartialBackoffSurvivesAdmissibilityOnlyDrift(t *testing.T) {
	a, b, extra := activeSetContract(1), activeSetContract(2), activeSetContract(3)
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport { return readinessReport(ids, b) })
	f.provision(a, b, extra)
	f.verified(a, b)
	var allowed atomic.Bool
	allowed.Store(true)
	activeControllerSource(t, f.controller, &allowed)
	now := activeControllerClock(t, f)
	f.controller.Reconcile(context.Background())
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	// The failed batch's deadline is the policy clock at completion plus the
	// backoff the controller applied to it.
	deadline := f.activeSet.State().BatchRetryAt
	backoff := deadline - time.Duration(now.Load())
	if deadline != time.Hour || backoff != time.Hour || !f.controller.ReadyFor(a) {
		t.Fatal("partial/backoff control missing")
	}
	now.Store(int64(time.Second))
	for _, enabled := range []bool{false, true, false, true} {
		allowed.Store(enabled)
		f.controller.Reconcile(context.Background()) // Forced poll must not withdraw A or reset the clock.
		state := f.controller.PlanningState(verified[0])
		gotDeadline := f.activeSet.State().BatchRetryAt
		if !state.Acknowledged || state.Participating != enabled || f.preloads.Load() != 1 ||
			gotDeadline != deadline || f.controller.Status().LastError != "preload_failed" {
			t.Fatal("admissibility-only drift reset partial failure residence/backoff or native acknowledgement")
		}
	}
	f.verified(a, b, extra)
	f.controller.Reconcile(context.Background())
	if f.preloads.Load() != 2 || !f.controller.ReadyFor(a) || !f.controller.ReadyFor(extra) || f.controller.ReadyFor(b) {
		t.Fatal("retaining the old retry deadline blocked genuinely new verified membership")
	}
	// The controller's own backoff shows only in the delay it applies to the
	// next failure of the same batch: carried across drift it doubles, reset it
	// starts again at the minimum.
	retry := f.activeSet.State().BatchRetryAt
	for _, enabled := range []bool{false, true} {
		allowed.Store(enabled)
		f.controller.Reconcile(context.Background())
	}
	now.Store(int64(retry))
	f.controller.Reconcile(context.Background())
	if f.preloads.Load() != 3 || f.activeSet.State().BatchRetryAt != retry+2*backoff {
		t.Fatal("admissibility-only drift reset partial failure residence/backoff or native acknowledgement")
	}
}

// A blocked first projection owns capture->apply, not c.mu or transport. The
// second worker is deliberately started while it is held. An old implementation
// lets that worker complete first, then regresses the already-observed state.
func TestPreloadCaptureApplyCannotRegressNewerObservedAuthority(t *testing.T) {
	for _, change := range []string{"catalog", "admissibility"} {
		t.Run(change, func(t *testing.T) {
			a, b := activeSetContract(1), activeSetContract(2)
			f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport { return readinessReport(ids, "") })
			f.verified(a)
			var allowed, block atomic.Bool
			allowed.Store(true)
			entered, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			open := func() { once.Do(func() { close(release) }) }
			if !f.controller.SetSelectionSource(func(v []preload.VerifiedPreloadArtifact, _ bool) ([]preload.PreloadDemandIdentity, []string) {
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
			activeControllerClock(t, f)
			f.controller.Reconcile(context.Background())
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
				f.provision(b) // A new catalog generation whose only member is b.
				f.verified(b)
			} else {
				allowed.Store(false)
			}
			go func() {
				defer close(newDone)
				close(newStarted)
				if change == "catalog" {
					f.controller.Reconcile(context.Background())
				} else {
					f.controller.PlanningState(verified[0])
				}
			}()
			<-newStarted
			// The probing clock holds each policy sample for preloadLockHeldWindow
			// and a reconcile takes four, so an overtaking caller needs more than
			// four of those windows to finish.
			select {
			case <-newDone:
				t.Error("newer authority overtook a captured-but-unapplied predecessor")
			case <-time.After(10 * preloadLockHeldWindow):
			}
			open()
			for _, done := range []chan struct{}{oldDone, newDone} {
				select {
				case <-done:
				case <-time.After(5 * time.Second):
					t.Fatal("capture/apply callers did not drain")
				}
			}
			key, status := f.activeSet.Snapshot(), f.controller.Status()
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
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport { return readinessReport(ids, "") })
	f.verified(activeSetContract(1))
	var allowed atomic.Bool
	var refreshes atomic.Int64
	allowed.Store(true)
	if !f.controller.SetSelectionSource(func(v []preload.VerifiedPreloadArtifact, refresh bool) ([]preload.PreloadDemandIdentity, []string) {
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
	activeControllerClock(t, f)
	f.controller.Reconcile(context.Background())
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
	f.provision(activeSetContract(2)) // A new catalog generation with a different model.
	f.verified(activeSetContract(2))
	f.controller.ReadyFor(activeSetContract(2))
	// The retained advice is not readable. Advice kept for the replaced model
	// could reach the policy only as an advisory ID outside the verified set,
	// which closes the selection instead of keying it to the new identity.
	key := f.activeSet.Snapshot()
	if key.CatalogGeneration != f.generation || len(key.Verified) != 1 || refreshes.Load() != 1 {
		t.Fatal("new verified identity retained stale advisory data or scanned on request")
	}
}
