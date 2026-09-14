package codeidentity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// pushCooldown returns the per-device push budget for the active delivery mode.
func (t *deviceState) pushCooldown(alert bool) time.Duration {
	if alert {
		return t.alertPushCooldown
	}
	return t.backgroundPushCooldown
}

// allowPush reports whether the per-device push budget permits another push now,
// for the given delivery mode (alert is allowed to push far more often).
func (t *deviceState) allowPush(seKey string, alert bool) bool {
	if seKey == "" {
		return true // no device identity to throttle on; fall back to the loop's cap
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	last, ok := t.lastPush[seKey]
	return !ok || t.now().Sub(last) >= t.pushCooldown(alert)
}

// retryDelay is the loop's wait between wake-ups: a base spacing plus jitter.
// Decoupled from the push budget so attestation is noticed promptly.
func (t *deviceState) retryDelay() time.Duration {
	return t.retrySpacing + t.jitter(t.retryJitter)
}

func (t *deviceState) recordPush(seKey string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.lastPush[seKey] = t.now()
	t.mu.Unlock()
}

func codeAttestTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func codeAttestPushBudgetKey(seKey, tokenHash string) string {
	return seKey + "\x00" + tokenHash
}

// reservePush combines generation validation, local cooldown admission, and
// the durable cross-process compare-and-set. Its returned release function keeps
// the per-device lease held through identity recheck and push dispatch.
func (t *deviceState) reservePush(
	ctx context.Context,
	seKey, token string,
	alert bool,
	generation uint64,
) (func(), bool) {
	if seKey == "" || token == "" || generation == 0 {
		return nil, false
	}
	unlockReservation := t.lockPushReservation(seKey)

	tokenHash := codeAttestTokenHash(token)
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
	now := t.now()
	cooldown := t.pushCooldown(alert)
	budgetKey := codeAttestPushBudgetKey(seKey, tokenHash)
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
	// of fabricated fresh tokens is paced like a single token.
	if floor, ok := t.novelPushFloor[seKey]; ok && novelToken {
		if floor.After(now) {
			t.mu.Unlock()
			unlockReservation()
			return nil, false
		}
		delete(t.novelPushFloor, seKey)
	}
	if last, ok := t.lastPush[budgetKey]; ok &&
		now.Sub(last) < cooldown {
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
	st, hasDurableBudget := store.As[pushBudgetStore](t.store)
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
func (t *deviceState) noteBudgetTokenReservationHeld(seKey, tokenHash string) {
	order := t.budgetTokenOrder[seKey]
	if i := slices.Index(order, tokenHash); i >= 0 {
		order = append(order[:i], order[i+1:]...)
	}
	order = append(order, tokenHash)
	for len(order) > store.CodeAttestPushBudgetMaxTokenRows {
		evictedKey := codeAttestPushBudgetKey(seKey, order[0])
		delete(t.lastPush, evictedKey)
		delete(t.durableNextPush, evictedKey)
		order = order[1:]
	}
	t.budgetTokenOrder[seKey] = order
}

func (t *deviceState) tryReservePush(
	ctx context.Context,
	seKey, token string,
	alert bool,
	generation uint64,
) bool {
	release, ok := t.reservePush(ctx, seKey, token, alert, generation)
	if release != nil {
		release()
	}
	return ok
}
