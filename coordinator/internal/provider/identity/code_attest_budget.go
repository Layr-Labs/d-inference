package identity

import (
	"context"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (t *Throttle) BeginLoop(seKey string) uint64 {
	if seKey == "" {
		return 0
	}
	unlockReservation := t.lockPushReservation(seKey)
	defer unlockReservation()
	return t.beginLoopReservationHeld(seKey)
}

func (t *Throttle) beginLoopReservationHeld(seKey string) uint64 {
	generation := t.loopGeneration.Add(1)
	t.mu.Lock()
	t.loopGenerations[seKey] = generation
	delete(t.loopTokens, seKey)
	t.mu.Unlock()
	return generation
}

// rotateLoopAndClearPushBudget makes token-rotation ownership and budget reset
// one per-device operation. An old loop cannot reserve the just-cleared budget
// between the generation change and the new loop taking ownership. An honored
// (unthrottled) reset also clears the durable novel-token admission floor so
// the rotated token is challenged promptly across restarts and peers.
func (t *Throttle) RotateLoopAndClearPushBudget(
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

func (t *Throttle) LoopCurrent(seKey string, generation uint64) bool {
	if seKey == "" || generation == 0 {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.loopGenerations[seKey] == generation
}

func (t *Throttle) EndLoop(seKey string, generation uint64) {
	if seKey == "" || generation == 0 {
		return
	}
	t.mu.Lock()
	if t.loopGenerations[seKey] == generation {
		delete(t.loopGenerations, seKey)
		delete(t.loopTokens, seKey)
	}
	t.mu.Unlock()
}

func (t *Throttle) LoopCurrentForToken(
	seKey, token string,
	generation uint64,
) bool {
	if seKey == "" || token == "" || generation == 0 {
		return false
	}
	tokenHash := CodeAttestTokenHash(token)
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.loopGenerations[seKey] == generation &&
		t.loopTokens[seKey] == tokenHash
}

func (t *Throttle) lockPushReservation(seKey string) func() {
	t.mu.Lock()
	lock := t.reservationLocks[seKey]
	if lock == nil {
		lock = &reservationLock{}
		t.reservationLocks[seKey] = lock
	}
	lock.users++
	t.mu.Unlock()

	lock.mu.Lock()
	return func() {
		lock.mu.Unlock()
		t.mu.Lock()
		lock.users--
		if lock.users == 0 && t.reservationLocks[seKey] == lock {
			delete(t.reservationLocks, seKey)
		}
		t.mu.Unlock()
	}
}

// reservePush combines generation validation, local cooldown admission, and
// the durable cross-process compare-and-set. Its returned release function keeps
// the per-device lease held through identity recheck and push dispatch.
func (t *Throttle) ReservePush(
	ctx context.Context,
	seKey, token string,
	alert bool,
	generation uint64,
) (func(), bool) {
	if seKey == "" || token == "" || generation == 0 {
		return nil, false
	}
	unlockReservation := t.lockPushReservation(seKey)

	tokenHash := CodeAttestTokenHash(token)
	t.mu.Lock()
	if t.loopGenerations[seKey] != generation {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	if currentToken := t.loopTokens[seKey]; currentToken != "" &&
		currentToken != tokenHash {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	t.loopTokens[seKey] = tokenHash
	now := t.Now()
	cooldown := t.PushCooldown(alert)
	budgetKey := CodeAttestPushBudgetKey(seKey, tokenHash)
	_, seenLastPush := t.lastPush[budgetKey]
	_, seenDurablePush := t.durableNextPush[budgetKey]
	novelToken := !seenLastPush && !seenDurablePush
	if blockedUntil := t.novelTokenBlockedUntil[seKey]; blockedUntil.After(now) && novelToken {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	} else if !blockedUntil.IsZero() && !blockedUntil.After(now) {
		delete(t.novelTokenBlockedUntil, seKey)
	}
	// Per-SE-key admission floor: a token this device never budgeted may only
	// push once the floor from the LAST push (to any token) has elapsed. The
	// first-ever token has no floor and admits immediately; a reconnect churn
	// of fabricated fresh tokens is paced like a single token (Codex P1).
	if floor, ok := t.novelPushFloor[seKey]; ok && novelToken {
		if floor.After(now) {
			t.mu.Unlock()
			unlockReservation()
			return nil, false
		}
		delete(t.novelPushFloor, seKey)
	}
	if last, ok := t.lastPush[budgetKey]; !t.AllowsPush(last, ok, now, alert) {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	if next, ok := t.durableNextPush[budgetKey]; ok &&
		next.After(now) {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	reservationCooldown := max(cooldown, time.Nanosecond)
	next := now.Add(reservationCooldown)
	st, hasDurableBudget := store.As[PushBudgetStore](t.Store)
	t.mu.Unlock()

	if hasDurableBudget {
		admitted, err := st.ReserveCodeAttestPushBudget(
			ctx, seKey, tokenHash, now, next,
		)
		if err != nil || !admitted {
			unlockReservation()
			return nil, false
		}
	}

	t.mu.Lock()
	if t.loopGenerations[seKey] != generation ||
		t.loopTokens[seKey] != tokenHash {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	t.lastPush[budgetKey] = now
	t.durableNextPush[budgetKey] = next
	if next.After(t.novelPushFloor[seKey]) {
		t.novelPushFloor[seKey] = next
	}
	t.noteBudgetTokenReservationHeld(seKey, tokenHash)
	t.mu.Unlock()
	return unlockReservation, true
}

// noteBudgetTokenReservationHeld (t.mu held) tracks per-SE-key token budget
// entries in recency order and evicts the oldest beyond the durable cap, so
// lastPush/durableNextPush cannot grow unboundedly under token churn. An
// evicted token that returns falls back to the admission floor.
func (t *Throttle) noteBudgetTokenReservationHeld(seKey, tokenHash string) {
	order := t.budgetTokenOrder[seKey]
	if i := slices.Index(order, tokenHash); i >= 0 {
		order = append(order[:i], order[i+1:]...)
	}
	order = append(order, tokenHash)
	for len(order) > store.CodeAttestPushBudgetMaxTokenRows {
		evictedKey := CodeAttestPushBudgetKey(seKey, order[0])
		delete(t.lastPush, evictedKey)
		delete(t.durableNextPush, evictedKey)
		order = order[1:]
	}
	t.budgetTokenOrder[seKey] = order
}

// clearPushBudget drops the per-device push cooldown so the NEXT push is allowed
// immediately. Used on APNs token rotation: the cooldown tracks pushes to the OLD
// token, but Apple's push budget is per-token, so the freshly registered token has
// its own untouched budget. Without this, the rearm loop sets CodeAttested=false
// yet cannot challenge the new token until the old token's (up to 20-minute)
// background cooldown expires — derouting the provider for no reason (Codex #9).
//
// Anti-DoS: the reset is itself throttled to at most once per budgetClearCooldown
// per device, so a provider that floods token changes in heartbeats cannot reset
// the budget every time and spam APNs beyond the per-device budget. The cooldown
// is DURABLE (Codex 06:36Z P1): with a budget store wired, the clear is
// compare-and-set on the sentinel's persisted last-clear instant, so a
// coordinator restart (empty lastBudgetClear map) or a blue-green peer cannot
// grant one extra floor clear per deploy. Returns whether the budget was
// actually cleared (false = the reset was throttled).
func (t *Throttle) ClearPushBudget(ctx context.Context, seKey string) bool {
	if seKey == "" {
		return false
	}
	unlockReservation := t.lockPushReservation(seKey)
	defer unlockReservation()
	return t.clearPushBudgetReservationHeld(ctx, seKey)
}

// clearPushBudgetReservationHeld runs the full throttled clear (reservation
// lock held, t.mu NOT held across the store call). Admission order: the cheap
// process-local cooldown first, then the durable compare-and-set — the durable
// verdict is authoritative and is mirrored locally either way, so a throttled
// peer's flood settles into the local fast path without further store traffic.
// Fail-closed: on store error nothing is cleared; the rotated token is only
// DELAYED until the floor elapses — the rate limit never weakens.
func (t *Throttle) clearPushBudgetReservationHeld(
	ctx context.Context, seKey string,
) bool {
	t.mu.Lock()
	now := t.Now()
	if last, ok := t.lastBudgetClear[seKey]; ok &&
		now.Sub(last) < t.BudgetClearCooldown {
		t.novelTokenBlockedUntil[seKey] = last.Add(t.BudgetClearCooldown)
		t.mu.Unlock()
		return false
	}
	st, hasDurable := store.As[PushBudgetStore](t.Store)
	cooldown := t.BudgetClearCooldown
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
	// registered token must be challengeable immediately (Codex #9). The reset
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
