package cachepersist_test

import (
	"testing"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

func (p *Persister) prunePending(now time.Time) {
	p.Mu.Lock()
	defer p.Mu.Unlock()
	p.PrunePendingBatch(now, 0)
}

// checkParkedExpiryIndex asserts the expiry order matches the parked set.
func checkParkedExpiryIndex(t *testing.T, p *Persister) {
	t.Helper()
	p.Mu.Lock()
	defer p.Mu.Unlock()
	checkKeyedTimeHeap(t, "expiry order", &p.ParkedExpiry, p.PendingCount, func(k crs.HolderKey) (time.Time, bool) {
		row, ok := p.Pending[p.ParkedBucket[k]][k]
		return row.ExpiresAt, ok
	})
}
