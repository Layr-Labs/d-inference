package registry_test

// The two time bounds the coordinator shares with the provider's member
// session. The provider measures the preparation window against its own wall
// clock and drops the connection when it exceeds 30 seconds; it anchors the
// owner's fixed lifetime to that same clock. The coordinator therefore grants
// 25 seconds, and still waits for an owner as if the member had measured the
// full 30.

import (
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	// preparationWindow is what the coordinator grants.
	preparationWindow = 25 * time.Second
	// memberPreparationLimit is the provider's own maximum
	// (NativePairMemberSession: a larger measured window is refused).
	memberPreparationLimit = 30 * time.Second
	// ownerRetirementLimit is how long after the fixed expiry a departed
	// member's device stays held: the member's limit plus cleanup and slack.
	ownerRetirementLimit = memberPreparationLimit + 10*time.Second
)

func TestPreparationWindowToleratesAMemberClockFiveSecondsBehind(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		prepare := f.readPrepares(t)
		window := time.Until(time.Unix(0, prepare.PrepareBeforeUnixNano))
		if window != preparationWindow {
			t.Fatalf("granted preparation window is %s, want exactly %s", window, preparationWindow)
		}
		// A member whose clock is behind by d measures the window d longer.
		for behind, accepted := range map[time.Duration]bool{0: true, 5 * time.Second: true, 5*time.Second + time.Millisecond: false} {
			if measured := window + behind; (measured <= memberPreparationLimit) != accepted {
				t.Fatalf("a member %s behind measures %s against its %s limit; accepted should be %v", behind, measured, memberPreparationLimit, accepted)
			}
		}
	})
}

func TestPreparationCommitsOnlyInsideTheGrantedWindow(t *testing.T) {
	for name, tc := range map[string]struct {
		answerAfter time.Duration
		commits     bool
	}{
		"just inside the window": {preparationWindow - time.Millisecond, true},
		"at the window's end":    {preparationWindow, false},
	} {
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				f := newFormationFixture(t)
				defer f.close()
				f.attach(t, 0, nil)
				f.attach(t, 1, nil)
				f.readPrepares(t)
				time.Sleep(tc.answerAfter)
				synctest.Wait()
				if !tc.commits {
					// The window lapsed first: both members are told to cancel
					// and a late receipt cannot start an owner.
					for rank := range f.n {
						f.read(t, rank, protocol.TypeNativePairCancel)
					}
					if err := f.c.Handle(f.n[0], f.sign(t, 0, protocol.TypeNativePairPrepared, f.starts[0])); err == nil {
						t.Fatal("a preparation receipt was accepted after the window")
					}
					return
				}
				f.commit(t)
				if v := f.view(t); v.State != production.NativePairStateActive {
					t.Fatalf("a pair prepared inside the window is %s, want active", v.State)
				}
			})
		})
	}
}

// Shortening the granted window does not shorten how long a departed member's
// owner may still be running: that follows the member's own 30-second limit.
func TestDepartedOwnerHoldLastsTheMembersLimitPastExpiry(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		expires := time.Unix(0, f.readPrepares(t).ExpiresAtUnixNano)
		f.commit(t)
		leaderStart := f.starts[0]

		f.leave(1)
		f.read(t, 0, protocol.TypeNativePairCancel)
		if err := f.c.Handle(f.n[0], f.sign(t, 0, protocol.TypeNativePairOwnerReleased, releaseReceipt(leaderStart))); err != nil {
			t.Fatalf("leader release receipt: %v", err)
		}
		f.attach(t, 1, nil)
		f.quiet(t, time.Until(expires.Add(ownerRetirementLimit-time.Second)), "a device inside the owner retirement limit")
		if v := f.view(t); v.Waiting != production.NativePairWaitingHeld {
			t.Fatalf("device is not held one second before the limit: %+v", v)
		}
		// The selector's next pass after the limit forms the next session.
		sleepUntil(expires.Add(ownerRetirementLimit))
		f.nextPrepares(t, 2*time.Second)
	})
}
