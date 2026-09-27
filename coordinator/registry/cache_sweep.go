package registry

import "time"

// cacheRoutingMaxSweepRemovals bounds the holder removals and the attempt
// removals of one sweep, each. Expiry is call-driven and runs under t.mu, which
// the routing path also takes (matchingHolders): after a traffic lull longer
// than the TTL every entry is stale at once, and removing up to
// cacheRoutingMaxEntries of them in one pass would stall routing. A sweep that
// spends a budget sets sweepBacklog, so the following tracker operations keep
// draining instead of waiting for the next interval. At a full index one
// budget of holders measured 0.7 ms mean and 1.3 ms at most
// (BenchmarkCacheSweepMassExpiry); 4,096 measured 3 ms and up to 7.6 ms.
// Correctness never depends on the sweep: activeHolderLocked and
// activeAttemptLocked check every entry against its own expiry, so a stale
// entry that is still present is never returned.
const cacheRoutingMaxSweepRemovals = 1_024

// sweepLocked expires from the heads of the expiry-ordered heaps. Its cost is
// O(expired · log n) and independent of how many live entries exist. It
// reports whether a budget ran out, that is, whether expired entries may
// remain.
func (t *cacheRoutingTracker) sweepLocked(now time.Time) bool {
	holders, _ := t.expireHoldersLocked(now, cacheRoutingMaxSweepRemovals)
	attempts := t.expireAttemptsLocked(now, cacheRoutingMaxSweepRemovals)
	// Fences are keyed by (provider, model, tier): bounded by the connected
	// fleet rather than by traffic, and this walk is also the count the
	// lifecycle status reports.
	t.sweepFencesLocked(now)
	return holders == cacheRoutingMaxSweepRemovals || attempts == cacheRoutingMaxSweepRemovals
}

// expireHoldersLocked removes at most limit expired holders. examined counts
// the heap heads it looked at: the removed entries plus, when it stopped at a
// live one, that one.
func (t *cacheRoutingTracker) expireHoldersLocked(now time.Time, limit int) (removed, examined int) {
	for removed < limit && len(t.holderOrder) > 0 {
		head := t.holderOrder[0]
		examined++
		if now.Before(head.expiresAt) {
			break
		}
		t.removeHolderLocked(head.ref.key, head.ref.providerID, cacheHolderRemovalTTL)
		removed++
	}
	return removed, examined
}

func (t *cacheRoutingTracker) expireAttemptsLocked(now time.Time, limit int) (removed int) {
	for removed < limit && len(t.attemptOrder) > 0 {
		head := t.attemptOrder[0]
		if now.Before(head.expiresAt) {
			break
		}
		t.removeAttemptLocked(head.nonce)
		removed++
	}
	return removed
}

func (t *cacheRoutingTracker) sweepIfDueLocked(now time.Time) {
	if !t.sweepBacklog && !t.lastSweep.IsZero() &&
		now.Before(t.lastSweep.Add(cacheRoutingSweepInterval)) {
		return
	}
	t.sweepBacklog = t.sweepLocked(now)
	t.lastSweep = now
}

// stateCounts settles expiry before counting, as the unbounded sweep did, but
// releases the lock between bounded passes so a status scrape that lands on a
// mass expiry never holds up routing for the whole drain. The pass limit is
// what draining both full indexes takes, so the loop ends even if receipts
// keep adding entries that are already stale.
func (t *cacheRoutingTracker) stateCounts(now time.Time) (holders, attempts int) {
	for pass := 1; ; pass++ {
		t.mu.Lock()
		t.sweepIfDueLocked(now)
		limit := (t.maxEntries+t.maxAttempts)/cacheRoutingMaxSweepRemovals + 1
		if !t.sweepBacklog || pass >= limit {
			holders, attempts = t.holderCount, len(t.attempts)
			t.mu.Unlock()
			return holders, attempts
		}
		t.mu.Unlock()
	}
}

// enforceCapLocked evicts from the head of the expiry heap: the holder that
// would lapse first, which forfeits the least remaining evidence. A head that
// has already expired but has not been swept yet is an expiry, not an
// eviction, so capacity_eviction counts only live evidence that the cap
// displaced.
func (t *cacheRoutingTracker) enforceCapLocked(now time.Time) {
	for t.holderCount > t.maxEntries {
		head := t.holderOrder[0]
		reason := cacheHolderRemovalCapacityEviction
		if !now.Before(head.expiresAt) {
			reason = cacheHolderRemovalTTL
		}
		t.removeHolderLocked(head.ref.key, head.ref.providerID, reason)
	}
}

// enforceAttemptCapLocked evicts the attempt that expires first, so terminal
// attempts waiting only for a late write-behind receipt go before in-flight
// ones.
func (t *cacheRoutingTracker) enforceAttemptCapLocked() {
	for len(t.attempts) > t.maxAttempts {
		t.removeAttemptLocked(t.attemptOrder[0].nonce)
	}
}
