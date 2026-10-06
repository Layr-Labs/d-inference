package cachetracker

import (
	"time"
) // SweepLocked expires from the heads of the expiry-ordered heaps. Its cost is
// O(expired · log n) and independent of how many live entries exist. It
// reports whether expired entries remain because a budget ran out.
func (t *Tracker[P]) SweepLocked(now time.Time) bool {
	t.ExpireHoldersLocked(now, cacheRoutingMaxSweepRemovals)
	t.ExpireAttemptsLocked(now, cacheRoutingMaxSweepRemovals)
	// Fences are keyed by (provider, model, tier): bounded by the connected
	// fleet rather than by traffic, and this walk is also the count the
	// lifecycle status reports.
	t.proofs.Sweep(now)
	// The heads say exactly whether anything expired is left, so a pass that
	// happened to end on its budget does not re-arm for nothing.
	return (t.holderOrder.Len() > 0 && !now.Before(t.holderOrder.Head().ExpiresAt())) ||
		(t.attemptOrder.Len() > 0 && !now.Before(t.attemptOrder.Head().ExpiresAt()))
}

// ExpireHoldersLocked removes at most limit expired holders. examined counts
// the heap heads it looked at: the removed entries plus, when it stopped at a
// live one, that one.
func (t *Tracker[P]) ExpireHoldersLocked(now time.Time, limit int) (removed, examined int) {
	for removed < limit && t.holderOrder.Len() > 0 {
		head := t.holderOrder.Head()
		examined++
		if now.Before(head.ExpiresAt()) {
			break
		}
		t.RemoveHolderLocked(head.Key().Key, head.Key().ProviderID, cacheHolderRemovalTTL)
		removed++
	}
	return removed, examined
}

func (t *Tracker[P]) ExpireAttemptsLocked(now time.Time, limit int) (removed int) {
	for removed < limit && t.attemptOrder.Len() > 0 {
		head := t.attemptOrder.Head()
		if now.Before(head.ExpiresAt()) {
			break
		}
		t.RemoveAttemptLocked(head.Key().Nonce)
		removed++
	}
	return removed
}

func (t *Tracker[P]) SweepIfDueLocked(now time.Time) {
	if !t.sweepBacklog && !t.lastSweep.IsZero() &&
		now.Before(t.lastSweep.Add(cacheRoutingSweepInterval)) {
		return
	}
	t.sweepBacklog = t.SweepLocked(now)
	t.lastSweep = now
}

// EnforceCapLocked evicts from the head of the expiry heap: the holder that
// would lapse first, which forfeits the least remaining evidence. A head that
// has already expired but has not been swept yet is an expiry, not an
// eviction, so capacity_eviction counts only live evidence that the cap
// displaced.
//
// The loops stop on an empty heap as well: if the heap and the maps ever
// drifted apart, the index would stay over its cap rather than panic the
// coordinator.
func (t *Tracker[P]) EnforceCapLocked(now time.Time) {
	for t.holders.Len() > t.maxEntries && t.holderOrder.Len() > 0 {
		head := t.holderOrder.Head()
		t.RemoveHolderLocked(head.Key().Key, head.Key().ProviderID,
			CacheCapRemovalReason(head.ExpiresAt(), now))
	}
}

func CacheCapRemovalReason(expiresAt, now time.Time) RemovalReason {
	if !now.Before(expiresAt) {
		return cacheHolderRemovalTTL
	}
	return cacheHolderRemovalCapacityEviction
}

// EnforceAttemptCapLocked evicts the attempt that expires first, so terminal
// attempts waiting only for a late write-behind receipt go before in-flight
// ones.
func (t *Tracker[P]) EnforceAttemptCapLocked() {
	for t.attempts.Len() > t.maxAttempts && t.attemptOrder.Len() > 0 {
		t.RemoveAttemptLocked(t.attemptOrder.Head().Key().Nonce)
	}
}
