package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Reset and all three trailing-fault recorders must remain independent of the
// fleet lock in both reservation modes. Otherwise the wave integration puts
// the old write-lock convoy back on request completion.
func TestVersionResetAndLateFlushDoNotWaitForRegistryLock(t *testing.T) {
	for _, mode := range []string{"shared", "global"} {
		t.Run(mode, func(t *testing.T) {
			t.Setenv(envReserveCommitMode, mode)
			r := New(testLogger())
			bindVersionedSession(t, r, "old", "0.9.0", true)
			dieAbruptlyWithFlush(t, r, "old")
			p := bindVersionedSession(t, r, "new", "0.9.0", true)
			r.mu.Lock()
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
				r.mu.Unlock()
				if !superseded {
					t.Fatal("old-session flush was not superseded by the version reset")
				}
			case <-time.After(2 * time.Second):
				r.mu.Unlock()
				<-done
				t.Fatal("version reset or late-flush recorder waited for the registry lock")
			}
			assertIdentityQuarantine(t, r, "new", false)
		})
	}
}
