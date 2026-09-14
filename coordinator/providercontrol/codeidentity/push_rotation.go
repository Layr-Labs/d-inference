package codeidentity

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// rotateLoopAndClearPushBudget makes token-rotation ownership and budget reset
// one per-device operation. An old loop cannot reserve the just-cleared budget
// between the generation change and the new loop taking ownership. An honored
// (unthrottled) reset also clears the durable novel-token admission floor so
// the rotated token is challenged promptly across restarts and peers.
func (t *deviceState) rotateLoopAndClearPushBudget(
	ctx context.Context, seKey string,
) uint64 {
	if seKey == "" {
		return 0
	}
	unlockReservation := t.lockPushReservation(seKey)
	defer unlockReservation()
	generation := t.beginLoopReservationHeld(seKey)
	t.clearPushBudgetReservationHeld(ctx, seKey)
	return generation
}

// clearPushBudgetReservationHeld runs the full throttled clear (reservation
// lock held, t.mu NOT held across the store call). Admission order: the cheap
// process-local cooldown first, then the durable compare-and-set — the durable
// verdict is authoritative and is mirrored locally either way, so a throttled
// peer's flood settles into the local fast path without further store traffic.
// Fail-closed: on store error nothing is cleared; the rotated token is only
// DELAYED until the floor elapses — the rate limit never weakens.
func (t *deviceState) clearPushBudgetReservationHeld(
	ctx context.Context, seKey string,
) bool {
	t.mu.Lock()
	now := t.now()
	if last, ok := t.lastBudgetClear[seKey]; ok &&
		now.Sub(last) < t.budgetClearCooldown {
		t.novelTokenBlockedUntil[seKey] = last.Add(t.budgetClearCooldown)
		t.mu.Unlock()
		return false
	}
	st, hasDurable := store.As[pushBudgetStore](t.store)
	cooldown := t.budgetClearCooldown
	t.mu.Unlock()

	if hasDurable {
		lastClear, cleared, err := st.ClearCodeAttestPushFloor(
			ctx, seKey, now, cooldown,
		)
		if err != nil {
			return false
		}
		if !cleared {
			// Another instance (or a pre-restart clear) already spent this
			// window. Mirror the durable verdict locally so the next flood
			// attempt short-circuits without a store round-trip.
			t.mu.Lock()
			if lastClear.After(t.lastBudgetClear[seKey]) {
				t.lastBudgetClear[seKey] = lastClear
			}
			if blocked := lastClear.Add(cooldown); blocked.After(t.novelTokenBlockedUntil[seKey]) {
				t.novelTokenBlockedUntil[seKey] = blocked
			}
			t.mu.Unlock()
			return false
		}
	}

	t.mu.Lock()
	t.lastBudgetClear[seKey] = now
	delete(t.novelTokenBlockedUntil, seKey)
	// An honored rotation lifts the novel-token admission floor: the freshly
	// registered token must be challengeable immediately. The reset
	// itself is budgetClearCooldown-throttled — durably when a store is wired —
	// so floor lifting cannot be flooded into unbounded novel-token admissions.
	delete(t.novelPushFloor, seKey)
	// Composite (SE, token-hash) entries intentionally survive rotation. They
	// preserve A-B-A cooldowns; a genuinely new token has no composite entry and
	// therefore receives its independent budget. Only pre-composite legacy keys
	// are safe to clear here.
	delete(t.lastPush, seKey)
	delete(t.durableNextPush, seKey)
	t.mu.Unlock()
	return true
}
