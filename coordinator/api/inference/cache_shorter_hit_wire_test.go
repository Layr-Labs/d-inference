package inference

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A provider that stops rotating its epoch on per-file eviction reports a
// removed deeper checkpoint only as a valid hit at a shallower one. Over the
// real provider WebSocket, that hit drops the deeper holder under its own
// removal reason, keeps the shallower one, and applies no fence.
func TestShorterHitDropsDeeperHolderOverProviderWire(t *testing.T) {
	capability := cacheEligibilityV2Capability("model")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	w := newCacheReceiptWire(t, capability)
	short, long := w.boundary(8), w.boundary(16) // 2,048 and 4,096 tokens

	donor := w.attempt("donor")
	w.lookup("donor", donor, nil)
	w.waitReceipt("lookup_v2", "accepted", "accepted", 1)
	w.ready("donor", donor, 100, short, long)
	w.waitReceipt("ready_v2", "accepted", "accepted", 1)
	w.waitStatus(func(s ExactCacheStatus) bool { return s.Holders == 2 })

	w.lookup("repeat", w.attempt("repeat"), func(m *protocol.PrefixCacheLookupV2Message) {
		m.Outcome, m.MatchedAnchor = "hit", &short
		m.ExpectedPrefillTokensSaved, m.StageMs = short.TokenCount, 50
	})
	w.waitReceipt("lookup_v2", "accepted", "accepted", 2)
	status := w.waitStatus(func(s ExactCacheStatus) bool {
		return s.Holders == 1 && s.Lifecycle.HolderRemoved["shorter_hit"] == 1
	})
	lifecycle := status.Lifecycle
	if lifecycle.HolderRemoved["miss_invalidation"] != 0 || lifecycle.HolderRemoved["proof_mismatch"] != 0 {
		t.Fatalf("shorter hit counted under another removal reason: %+v", lifecycle.HolderRemoved)
	}
	if lifecycle.FencesApplied != 0 || lifecycle.FencedCapabilities != 0 {
		t.Fatalf("shorter hit fenced the capability: %+v", lifecycle)
	}
	if lifecycle.SSDHits != 1 {
		t.Fatalf("ssd hits = %d, want the shorter hit counted once", lifecycle.SSDHits)
	}

	// The capability still proves receipts, and the deeper boundary is
	// re-taught by the next durable publication.
	again := w.attempt("again")
	w.lookup("again", again, func(m *protocol.PrefixCacheLookupV2Message) {
		m.Outcome, m.MatchedAnchor = "hit", &short
		m.ExpectedPrefillTokensSaved, m.StageMs = short.TokenCount, 50
	})
	w.waitReceipt("lookup_v2", "accepted", "accepted", 3)
	w.ready("again", again, 100, long)
	w.waitReceipt("ready_v2", "accepted", "accepted", 2)
	w.waitStatus(func(s ExactCacheStatus) bool {
		return s.Holders == 2 && s.Lifecycle.HolderRemoved["shorter_hit"] == 1
	})
}
