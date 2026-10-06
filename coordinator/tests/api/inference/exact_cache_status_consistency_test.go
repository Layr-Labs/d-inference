package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Counting holders settles expiry, so one scrape must count before it reads
// the lifecycle counters: holder_added minus every removal is the holder
// count in each response of GET /v1/cache/status, also in the first one
// after the holders expired.
func TestExactCacheStatusCountsAgreeWithLifecycleAfterExpiry(t *testing.T) {
	capability := cacheEligibilityV2Capability("model")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	w := newCacheReceiptWire(t, capability)
	donor := w.attempt("donor")
	w.lookup("donor", donor, nil)
	w.waitReceipt("lookup_v2", "accepted", "accepted", 1)
	w.ready("donor", donor, 100, w.boundary(8), w.boundary(16))
	w.waitReceipt("ready_v2", "accepted", "accepted", 1)

	scrapes := 0
	consistent := func(status ExactCacheStatus) {
		t.Helper()
		scrapes++
		removed := uint64(0)
		for _, count := range status.Lifecycle.HolderRemoved {
			removed += count
		}
		if status.Lifecycle.HolderAdded-removed != uint64(status.Holders) {
			t.Fatalf("scrape %d: holders=%d but holder_added=%d removed=%d (%+v)", scrapes,
				status.Holders, status.Lifecycle.HolderAdded, removed, status.Lifecycle.HolderRemoved)
		}
	}
	w.waitStatus(func(status ExactCacheStatus) bool {
		consistent(status)
		return status.Holders == 2
	})

	w.advance(31 * time.Minute) // the default holder TTL is thirty minutes
	status := w.waitStatus(func(status ExactCacheStatus) bool {
		consistent(status)
		return status.Holders == 0
	})
	if status.Lifecycle.HolderRemoved["ttl"] != 2 || status.Lifecycle.HolderAdded != 2 {
		t.Fatalf("expiry not reported: %+v", status.Lifecycle)
	}
	consistent(w.srv.ExactCacheStatusSnapshot())
}
