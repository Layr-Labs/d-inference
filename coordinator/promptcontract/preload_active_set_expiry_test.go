package promptcontract

import (
	"testing"
	"time"
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
			input := activeSetInput(3, 1)
			input.PubliclyAvailable = []string{input.Verified[0].ModelID}
			policy := newPreloadActiveSet()
			activeSetReconcile(t, policy, 0, input)
			activeSetDemand(t, policy, 0, input.Verified[0], input.Verified[1])
			activeSetReconcile(t, policy, 0, input)
			activeSetWant(t, policy, 1)
			failed, ok := policy.beginAttempt(0)
			if !ok || !policy.completeAttempt(0, failed, nil, test.backoff) {
				t.Fatal("setup did not record A's failed attempt and selected backoff")
			}
			activeSetReconcile(t, policy, time.Second, input)
			activeSetWant(t, policy, 2)
			activeSetLoadAll(t, policy, time.Second)

			// A's last demand was at zero, so t=301s exceeds the five-minute
			// lifetime. C has never been demanded. Both now start at one tick;
			// A is publicly available and C is eligible but privately supplied.
			const renewed = 301 * time.Second
			activeSetDemand(t, policy, renewed, input.Verified[0], input.Verified[2])
			if policy.demand[input.Verified[0]].waitingSince != renewed || policy.demand[input.Verified[2]].waitingSince != renewed {
				t.Fatal("fixture did not establish fresh equal-age A/C demand")
			}
			if test.backoff > renewed && policy.retryAt[activeSetContract(1)] != test.backoff {
				t.Fatal("fresh demand erased a still-active failure deadline")
			}
			activeSetReconcile(t, policy, renewed, input)
			activeSetWant(t, policy, test.wantMember)
		})
	}
}
