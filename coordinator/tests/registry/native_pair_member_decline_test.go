package registry_test

// A provider build whose installed owner cannot serve a committed start yet
// answers every preparation with a signed native_pair_cancel. That is a
// steady state on real machines, not a fault: it must stay cheap for both
// sides, visible as what it is, and it must not accumulate anything.

import (
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// decline answers the current preparation the way such a member does.
func (f *formationFixture) decline(t *testing.T, rank int) {
	t.Helper()
	if err := f.c.Handle(f.n[rank], f.sign(t, rank, protocol.TypeNativePairCancel, []byte("DBNC\x01"))); err != nil {
		t.Fatalf("signed decline from rank%d refused: %v", rank, err)
	}
	for member := range f.n {
		f.read(t, member, protocol.TypeNativePairCancel)
	}
	synctest.Wait()
}

func memberGate(t *testing.T, r *production.Registry, id string) string {
	t.Helper()
	for _, row := range r.FleetSample(time.Now()) {
		if row.ProviderID == id {
			return row.EligibilityReason
		}
	}
	t.Fatalf("no fleet sample row for %s", id)
	return ""
}

func TestMemberThatAlwaysDeclinesIsOfferedRarelyAndHoldsNothing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)

		// More cycles than the relay's session table or one hour could hide.
		const cycles = 80
		began := time.Now()
		var offered []time.Time
		for cycle := 0; cycle < cycles; cycle++ {
			f.nextPrepares(t, 20*time.Minute)
			offered = append(offered, time.Now())
			f.decline(t, cycle%2)

			v := f.view(t)
			if v.State != production.NativePairStateWaiting || v.Waiting != production.NativePairWaitingDeclined ||
				v.Declines != cycle+1 || v.Failures != 0 || !v.RetryAt.After(time.Now()) {
				t.Fatalf("cycle %d: a declined preparation is reported as %s/%q declines=%d failures=%d retry=%s",
					cycle, v.State, v.Waiting, v.Declines, v.Failures, v.RetryAt)
			}
			// Declining frees both devices at once: nothing is held while waiting.
			for rank, member := range f.p {
				if gate := memberGate(t, f.r, member.ID); gate != "member_only" {
					t.Fatalf("cycle %d: rank%d is %q between offers, want no pair hold", cycle, rank, gate)
				}
			}
		}

		// Offers start 30 s apart and widen to one every 15 minutes.
		for i, want := range []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 15 * time.Minute, 15 * time.Minute} {
			if gap := offered[i+1].Sub(offered[i]); gap < want || gap > want+2*time.Second {
				t.Fatalf("offer %d followed the previous one after %s, want about %s", i+2, gap, want)
			}
		}
		// A member's control remembers 1,024 session epochs per process. At
		// the steady rate that memory must last well over a week.
		steady := offered[cycles-1].Sub(offered[cycles-2])
		if lasts := 1024 * steady; lasts < 10*24*time.Hour {
			t.Fatalf("steady offers every %s exhaust a member's 1,024 epochs in %s", steady, lasts)
		}
		if elapsed := time.Since(began); elapsed < 18*time.Hour {
			t.Fatalf("%d declined offers took only %s", cycles, elapsed)
		}
	})
}

// A decline is not a failure, and neither outlives a session that commits.
func TestDeclinesAndFailuresAreCountedApartAndClearedByACommit(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		f.readPrepares(t)
		f.decline(t, 1)

		// The next preparation is never answered: that one is a failure.
		f.nextPrepares(t, time.Minute)
		for rank := range f.n {
			select {
			case m := <-f.frames[rank]:
				if m.Type != protocol.TypeNativePairCancel {
					t.Fatalf("rank%d got %s while its preparation lapsed", rank, m.Type)
				}
			case <-time.After(time.Minute):
				t.Fatal("lapsed preparation was not cancelled")
			}
		}
		synctest.Wait()
		if v := f.view(t); v.Waiting != production.NativePairWaitingRetry || v.Declines != 1 || v.Failures != 1 {
			t.Fatalf("after one decline and one lapse: %q declines=%d failures=%d", v.Waiting, v.Declines, v.Failures)
		}

		f.nextPrepares(t, time.Minute)
		f.commit(t)
		if v := f.view(t); v.State != production.NativePairStateActive || v.Declines != 0 || v.Failures != 0 {
			t.Fatalf("a committed session left declines=%d failures=%d", v.Declines, v.Failures)
		}
	})
}
