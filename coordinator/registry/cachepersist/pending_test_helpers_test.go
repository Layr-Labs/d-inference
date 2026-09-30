package cachepersist

import (
	"testing"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

func (p *Persister) prunePending(now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingBatchLocked(now, 0)
}

// checkParkedExpiryIndex asserts the expiry order matches the parked set.
func checkParkedExpiryIndex(t *testing.T, p *Persister) {
	t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	checkKeyedTimeHeap(t, "expiry order", &p.parkedExpiry, p.pendingCount, func(k crs.HolderKey) (time.Time, bool) {
		row, ok := p.pending[p.parkedBucket[k]][k]
		return row.ExpiresAt, ok
	})
}
