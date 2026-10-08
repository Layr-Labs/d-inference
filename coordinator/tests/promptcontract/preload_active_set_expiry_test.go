package promptcontract_test

import (
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
)

// Expired demand starts a fresh ordinary FIFO position. A failure whose backoff
// is already over must not silently outrank the selected availability tie rule;
// a still-active failure deadline must nevertheless remain authoritative.
func TestPreloadActiveSetFreshDemandDoesNotInheritExpiredFailurePriority(t *testing.T) {
	for _, test := range []struct {
		name       string
		backoff    time.Duration
		wantMember int
	}{
		{"expired_backoff_uses_fresh_availability_tie", 60 * time.Second, 1},
		{"active_backoff_still_excludes_failed_member", 600 * time.Second, 3},
	} {
		t.Run(test.name, func(t *testing.T) {
			// A's last demand was at zero, so t=301s exceeds the five-minute
			// lifetime. C has never been demanded. Both now start at one tick;
			// A is publicly available and C is eligible but privately supplied.
			const renewed = 301 * time.Second
			// renew replays the fixture through that renewed demand, with the
			// given tuple as the publicly available one.
			renew := func(public int) (*preload.PreloadActiveSet, preload.PreloadSelectionInput) {
				input := activeSetInput(3, 1)
				input.PubliclyAvailable = []string{input.Verified[public].ModelID}
				policy := preload.NewPreloadActiveSet()
				activeSetReconcile(t, policy, 0, input)
				activeSetDemand(t, policy, 0, input.Verified[0], input.Verified[1])
				activeSetReconcile(t, policy, 0, input)
				activeSetWant(t, policy, 1)
				failed, ok := policy.BeginAttempt(0)
				if !ok || !policy.CompleteAttempt(0, failed, nil, test.backoff) {
					t.Fatal("setup did not record A's failed attempt and selected backoff")
				}
				activeSetReconcile(t, policy, time.Second, input)
				activeSetWant(t, policy, 2)
				activeSetLoadAll(t, policy, time.Second)
				activeSetDemand(t, policy, renewed, input.Verified[0], input.Verified[2])
				return policy, input
			}
			// Wait ages are not readable. Equal fresh ages show in the tie rule
			// alone deciding: with C the available one instead, C must win. An
			// A that kept its expired wait would win on age either way.
			control, controlInput := renew(2)
			activeSetReconcile(t, control, renewed, controlInput)
			if !slices.Equal(control.Snapshot().Desired, activeSetContracts(3)) {
				t.Fatal("fixture did not establish fresh equal-age A/C demand")
			}
			policy, input := renew(0)
			activeSetReconcile(t, policy, renewed, input)
			// A deadline that A's fresh demand erased would let the available A
			// take this slot.
			if test.backoff > renewed && slices.Equal(policy.Snapshot().Desired, activeSetContracts(1)) {
				t.Fatal("fresh demand erased a still-active failure deadline")
			}
			activeSetWant(t, policy, test.wantMember)
			if test.backoff > renewed {
				// The deadline is still exactly the selected backoff: A stays
				// excluded one tick before it and replaces C at it.
				activeSetLoadAll(t, policy, renewed)
				activeSetReconcile(t, policy, test.backoff-1, input)
				excluded := slices.Equal(policy.Snapshot().Desired, activeSetContracts(3))
				activeSetReconcile(t, policy, test.backoff, input)
				if !excluded || !slices.Equal(policy.Snapshot().Desired, activeSetContracts(1)) {
					t.Fatal("fresh demand erased a still-active failure deadline")
				}
			}
		})
	}
}
