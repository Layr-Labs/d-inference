package api

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A proof mismatch received over the provider WebSocket fences the capability
// for a bounded window: receipts inside it are rejected as capability_fenced,
// /v1/cache/status counts the window, and a valid proof after it is accepted.
func TestProofFenceLiftsOverProviderWire(t *testing.T) {
	w := newCacheReceiptWire(t, cacheEligibilityV2Capability("model"))

	w.lookup("mismatch", w.attempt("mismatch"), func(m *protocol.PrefixCacheLookupV2Message) {
		m.PromptAnchor.ChainHash = strings.Repeat("d", 64)
	})
	w.waitReceipt("lookup_v2", "rejected", "prompt_anchor_mismatch", 1)
	w.waitStatus(func(s ExactCacheStatus) bool {
		return s.Lifecycle.FencesApplied == 1 && s.Lifecycle.FencesExpired == 0 &&
			s.Lifecycle.FencedCapabilities == 1
	})

	w.lookup("fenced", w.attempt("fenced"), nil)
	w.waitReceipt("lookup_v2", "rejected", "capability_fenced", 1)

	w.advance(61 * time.Second)
	w.lookup("accepted", w.attempt("accepted"), nil)
	w.waitReceipt("lookup_v2", "accepted", "accepted", 1)
	status := w.waitStatus(func(s ExactCacheStatus) bool {
		return s.Lifecycle.FencesApplied == 1 && s.Lifecycle.FencesExpired == 1 &&
			s.Lifecycle.FencedCapabilities == 0
	})
	if status.Lifecycle.HolderRemoved["proof_mismatch"] != 0 {
		t.Fatalf("mismatch with no holders reported removals: %+v", status.Lifecycle.HolderRemoved)
	}
}
