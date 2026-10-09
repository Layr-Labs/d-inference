package registry_test

import (
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A control-only member refuses solo work for as long as it runs, so every
// heartbeat it sends carries status "draining". That is its steady state, not
// a reason to keep it out of a pair: both members of a real pair report it.
func TestPairSelectorFormsMembersThatReportDraining(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		for rank := range f.p {
			f.r.Heartbeat(f.p[rank].ID, &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat,
				Status:          protocol.HeartbeatStatusDraining,
				BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{}}})
			if !f.r.ProviderDraining(f.p[rank].ID) {
				t.Fatalf("rank%d heartbeat did not mark the member draining", rank)
			}
		}
		f.readPrepares(t)
		f.commit(t)
	})
}

// A machine's record of how earlier requests fared is not a reason to keep it
// out of a pair either: fault trackers follow the machine's stable identity,
// so a Mac that served alone before would otherwise carry them into its
// membership.
func TestPairSelectorFormsMembersWithRequestFaultCooldowns(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		// The selector may already have offered a pair; end it so the next
		// offer is made with the cooldowns in place.
		f.readPrepares(t)
		for rank := range f.p {
			if !f.r.RecordDispatchLoadFailure(f.p[rank].ID, nativePairFixtureModel) {
				t.Fatalf("fixture cooldown did not start for rank%d", rank)
			}
		}
		for rank := range f.n {
			select {
			case m := <-f.frames[rank]:
				if m.Type != protocol.TypeNativePairCancel {
					t.Fatalf("rank%d got %s while its preparation lapsed", rank, m.Type)
				}
			case <-time.After(40 * time.Second):
				t.Fatal("lapsed preparation was not cancelled")
			}
		}
		f.nextPrepares(t, time.Minute)
		f.commit(t)
	})
}
