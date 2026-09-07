package registry

// remainingSlotTokenBudget is the model-local admission ceiling after debiting
// coordinator reservations not yet reflected in the heartbeat. Keep this
// separate from pooled headroom: private grants cannot borrow an idle peer's
// bytes, including when the peers use different KV storage formats.
// Callers use it only when the slot reports a positive maximum.
func remainingSlotTokenBudget(snap *routingSnapshot) int64 {
	extra := int64(snap.pendingMaxTokens) - committedTokenBudget(snap)
	if extra < 0 {
		extra = 0
	}
	remaining := snap.activeTokenBudgetMax - snap.activeTokenBudgetUsed - snap.queuedTokenBudget
	if remaining <= 0 || extra >= remaining {
		return 0
	}
	return remaining - extra
}
