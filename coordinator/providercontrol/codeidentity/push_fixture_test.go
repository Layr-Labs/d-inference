package codeidentity

import "context"

// tryReservePush exercises production admission and releases its lease before
// the fixture's next operation. Production retains that lease through dispatch.
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

// clearPushBudget lets store-contract fixtures observe the reset verdict while
// using the same per-device reservation lock as production token rotation.
func (t *deviceState) clearPushBudget(ctx context.Context, seKey string) bool {
	if seKey == "" {
		return false
	}
	unlockReservation := t.lockPushReservation(seKey)
	defer unlockReservation()
	return t.clearPushBudgetReservationHeld(ctx, seKey)
}
