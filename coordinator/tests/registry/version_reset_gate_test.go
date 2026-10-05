package registry_test

import (
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type versionDisconnectBarrier struct {
	warmplan.LoadState
	entered chan struct{}
	release chan struct{}
}

func (b *versionDisconnectBarrier) Reset() {
	b.LoadState.Reset()
	close(b.entered)
	<-b.release
}

// Reset and all three trailing-fault recorders must remain independent of the
// fleet lock in both reservation modes. Otherwise the wave integration puts
// the old write-lock convoy back on request completion.
func TestVersionResetAndLateFlushDoNotWaitForRegistryLock(t *testing.T) {
	for _, mode := range []string{"shared", "global"} {
		t.Run(mode, func(t *testing.T) {
			t.Setenv("EIGENINFERENCE_RESERVE_COMMIT_MODE", mode)
			barrier := &versionDisconnectBarrier{entered: make(chan struct{}), release: make(chan struct{})}
			r := production.NewWithDependencies(testLogger(), production.Dependencies{
				WarmLifecycle: func(id string) warmplan.LoadLifecycle {
					if id == "version-lock-holder" {
						return barrier
					}
					return new(warmplan.LoadState)
				},
			})
			bindVersionedSession(t, r, "old", "0.9.0", true)
			dieAbruptlyWithFlush(t, r, "old")
			p := bindVersionedSession(t, r, "new", "0.9.0", true)
			r.Register("version-lock-holder", nil, testRegisterMessage())
			disconnected := make(chan struct{})
			go func() {
				r.Disconnect("version-lock-holder")
				close(disconnected)
			}()
			release := sync.OnceFunc(func() {
				close(barrier.release)
				<-disconnected
			})
			t.Cleanup(release)
			// Disconnect resets the auxiliary provider's real load lifecycle
			// while holding the registry write lock, not the selected provider.
			select {
			case <-barrier.entered:
			case <-time.After(2 * time.Second):
				t.Fatal("disconnect did not reach the fleet-lock barrier")
			}
			done := make(chan bool, 1)
			go func() {
				p.SetVersion("0.9.1")
				for range 8 {
					r.RecordInferenceError("old", "m", 502, "base", protocol.CoordinatorCauseProviderDisconnected)
					r.RecordProviderOutcome("old", false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
					r.RecordProviderSessionServeOutcome("old", false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
				}
				done <- r.IsSupersededDisconnectFlush("old", 502, protocol.CoordinatorCauseProviderDisconnected)
			}()
			select {
			case superseded := <-done:
				release()
				if !superseded {
					t.Fatal("old-session flush was not superseded by the version reset")
				}
			case <-time.After(2 * time.Second):
				release()
				<-done
				t.Fatal("version reset or late-flush recorder waited for the registry lock")
			}
			assertIdentityQuarantine(t, r, "new", false)
		})
	}
}
