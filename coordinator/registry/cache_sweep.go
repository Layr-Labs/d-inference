package registry

import "time"

func (t *cacheRoutingTracker) sweepIfDueLocked(now time.Time) {
	t.core.SweepIfDueLocked(now)
}

// stateCounts settles expiry before counting, as the unbounded sweep did, but
// releases the lock between bounded passes so a status scrape that lands on a
// mass expiry never holds up routing for the whole drain. The pass limit is
// what draining both full indexes takes, so the loop ends even if receipts
// keep adding entries that are already stale.
func (t *cacheRoutingTracker) stateCounts(now time.Time) (holders, attempts int) {
	return t.maintenance.StateCounts(now)
}

// enforceAttemptCapLocked evicts the attempt that expires first, so terminal
// attempts waiting only for a late write-behind receipt go before in-flight
// ones.
func (t *cacheRoutingTracker) enforceAttemptCapLocked() {
	t.core.EnforceAttemptCapLocked()
}
