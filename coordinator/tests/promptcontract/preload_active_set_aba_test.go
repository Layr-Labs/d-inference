package promptcontract_test

import (
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
)

// Once an inflight lease loses authoritative identity, restoring byte-equal K
// cannot rehabilitate its old result. SelectionGeneration still changes only
// with D; irreversible operation invalidation is a separate required fence.
func TestPreloadActiveSetInflightInvalidationSurvivesFullKeyABA(t *testing.T) {
	for _, change := range []string{"admissibility_remove_restore", "overflow_verified_grow_shrink"} {
		t.Run(change, func(t *testing.T) {
			capacity := 2
			if change == "overflow_verified_grow_shrink" {
				capacity = 1
			}
			original := activeSetInput(2, capacity)
			policy := preload.NewPreloadActiveSet()
			activeSetReconcile(t, policy, 0, original)
			if capacity == 1 {
				activeSetDemand(t, policy, 0, original.Verified[0])
				activeSetReconcile(t, policy, 0, original)
			}
			old, ok := policy.BeginAttempt(0)
			if !ok {
				t.Fatal("setup did not create an inflight original lease")
			}
			changed := original
			if change == "admissibility_remove_restore" {
				changed.Admissible = slices.Clone(original.Verified[1:])
			} else {
				changed = activeSetInput(3, capacity)
			}
			during := activeSetReconcile(t, policy, time.Second, changed)
			if during.Equal(old.Key) || !slices.Equal(during.Desired, old.Key.Desired) || during.SelectionGeneration != old.Key.SelectionGeneration {
				t.Fatal("fixture must invalidate exact input without changing D/selection generation")
			}
			if _, admitted := policy.BeginAttempt(time.Second); admitted {
				t.Fatal("invalidation released the still-running operation prematurely")
			}
			restored := activeSetReconcile(t, policy, 2*time.Second, original)
			if !restored.Equal(old.Key) {
				t.Fatal("fixture must restore byte-equal full K, including the unchanged D generation")
			}
			if _, admitted := policy.BeginAttempt(2 * time.Second); admitted {
				t.Fatal("ABA restoration created overlapping preload before old completion")
			}
			if policy.CompleteAttempt(2*time.Second, old, old.Key.Desired, 0) {
				t.Fatal("full-key ABA rehabilitated an irrevocably invalidated inflight lease")
			}
			if len(policy.Successes()) != 0 {
				t.Fatal("old operation published successes after an invalidating transition")
			}
			// Only the actual callback retires the old operation. A new lease for
			// the now-current key must then be possible and independently usable.
			fresh, admitted := policy.BeginAttempt(2 * time.Second)
			if !admitted || fresh.Operation == old.Operation || !fresh.Key.Equal(restored) {
				t.Fatal("old callback did not retire ownership for a fresh current-key lease")
			}
			if !policy.CompleteAttempt(2*time.Second, fresh, fresh.Key.Desired, 0) {
				t.Fatal("fresh current-key acknowledgement failed after stale callback retirement")
			}
		})
	}
}
