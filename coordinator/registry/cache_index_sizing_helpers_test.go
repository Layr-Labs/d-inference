package registry

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"runtime"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// cacheSizingHarness builds exact-cache holders through the production
// receipt path (prepare → lookup → ready) of a real registry. Receipts are
// round-tripped through JSON first, so every holder owns freshly allocated
// strings exactly as a decoded provider frame does.
type cacheSizingHarness struct {
	tb         testing.TB
	r          *Registry
	provider   *Provider
	capability protocol.PrefixCacheV2Capability
	clock      *fenceTestClock
	seq        uint64
	// forgetAttempts drops each attempt at once instead of leaving it
	// terminal, isolating holder memory from attempt memory.
	forgetAttempts bool
}

func newCacheSizingHarness(tb testing.TB, ttl time.Duration) *cacheSizingHarness {
	tb.Helper()
	r := New(testLogger())
	if err := r.ConfigureCacheRouting(CacheRoutingConfig{
		Mode:          CacheRoutingOn,
		ActivationPct: 100,
		TTL:           ttl,
		MaxHolders:    defaultCacheRoutingMaxHolders,
		MasterKey: base64.RawURLEncoding.EncodeToString(
			[]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		tb.Fatal(err)
	}
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	provider := &Provider{
		ID:                  "0f6b3c1e-5a0d-4c58-9f7e-2b1d6a4c8e90",
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{"model": capability},
	}
	insertTestProvider(r, provider)
	clock := newFenceTestClock()
	r.SetCacheRoutingClockForTest(clock.Now)
	return &cacheSizingHarness{tb: tb, r: r, provider: provider, capability: capability, clock: clock}
}

func cacheSizingAnchor(index int) protocol.PrefixCacheAnchor {
	return protocol.PrefixCacheAnchor{
		TokenCount: int(promptcontract.BlockSize),
		ChainHash:  fmt.Sprintf("%064x", index+1),
	}
}

func (h *cacheSizingHarness) plan(index int) CachePlan {
	return boundTestCachePlan(h.r, exactTestPlan(cacheSizingAnchor(index)))
}

// donate records a holder the way a first request does: verified miss, then
// a durable ready publication.
func (h *cacheSizingHarness) donate(index int) CachePlan { return h.receipt(index, false) }

// hit records or refreshes a holder the way a repeat request does: a verified
// read, which also carries the stage measurement.
func (h *cacheSizingHarness) hit(index int) CachePlan { return h.receipt(index, true) }

func (h *cacheSizingHarness) receipt(index int, hit bool) CachePlan {
	h.tb.Helper()
	plan := h.plan(index)
	anchor := plan.Boundaries[0]
	id := "request-" + strconv.Itoa(index) + "-" + strconv.FormatUint(h.seq, 10)
	pr := &PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
	if err := h.r.PrepareCacheAttempt(pr, h.provider); err != nil {
		h.tb.Fatal(err)
	}
	nonce := preparedTestCacheMetadata(pr).CacheReceiptNonce
	if nonce == "" {
		h.tb.Fatalf("attempt %s was not prepared", id)
	}
	h.seq++
	lookup := testV2Lookup(nonce, h.capability, anchor, h.seq)
	lookup.RequestID = id
	if hit {
		lookup.Outcome, lookup.MatchedAnchor = "hit", &anchor
		lookup.ExpectedPrefillTokensSaved, lookup.StageMs = anchor.TokenCount, 120
	}
	if result := h.r.ApplyPrefixCacheLookupV2Result(h.provider.ID, wireCopy(h.tb, lookup)); !result.Accepted {
		h.tb.Fatalf("lookup %s rejected: %s", id, result.Reason)
	}
	if !hit {
		h.seq++
		ready := testV2Ready(nonce, h.capability, anchor, h.seq)
		ready.RequestID = id
		if result := h.r.ApplyPrefixCacheReadyV2Result(h.provider.ID, wireCopy(h.tb, ready)); !result.Accepted {
			h.tb.Fatalf("ready %s rejected: %s", id, result.Reason)
		}
	}
	if h.forgetAttempts {
		h.r.ForgetCacheAttempt(pr)
	} else {
		h.r.MarkCacheAttemptTerminal(pr)
	}
	return plan
}

func (h *cacheSizingHarness) matches(plan CachePlan, now time.Time) []cacheRoutingMatch {
	return h.r.cacheRouting.matchingHolders(plan, h.r.cacheRouteKeys.route, CacheRoutingOn, now)
}

func (h *cacheSizingHarness) removed(reason cacheHolderRemovalReason) uint64 {
	return h.r.CacheRoutingLifecycleStatus().HolderRemoved[string(reason)]
}

// indexSizes reads the raw index sizes without sweeping, unlike
// CacheRoutingStateCounts.
func (t *cacheRoutingTracker) indexSizes() (holders, holderHeap, attempts, attemptHeap int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.holderCount, len(t.holderOrder), len(t.attempts), len(t.attemptOrder)
}

func wireCopy[T any](tb testing.TB, message *T) *T {
	tb.Helper()
	raw, err := json.Marshal(message)
	if err != nil {
		tb.Fatal(err)
	}
	decoded := new(T)
	if err := json.Unmarshal(raw, decoded); err != nil {
		tb.Fatal(err)
	}
	return decoded
}

func settledHeapBytes() uint64 {
	runtime.GC()
	runtime.GC()
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return stats.HeapAlloc
}

// fillSyntheticHolders adds SSD-shaped holders straight through
// upsertHolderLocked under unrelated keys. Benchmarks use it to reach the cap
// quickly; every string is still a distinct allocation.
func fillSyntheticHolders(tracker *cacheRoutingTracker, count int, updatedAt time.Time) {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	for i := 0; i < count; i++ {
		at := updatedAt.Add(time.Duration(i) * time.Microsecond)
		tracker.upsertHolderLocked(fmt.Sprintf("filler-%036d", i), cacheHolder{
			ProviderID:         "provider-" + strconv.Itoa(i%512),
			ModelID:            "model",
			ModelAggregateHash: fmt.Sprintf("%064x", i),
			PromptContractID:   fmt.Sprintf("%064x", i),
			CacheEpoch:         fmt.Sprintf("%036d", i),
			Anchor:             cacheSizingAnchor(i),
			StageMs:            120,
			UpdatedAt:          at,
			ExpiresAt:          at.Add(tracker.ttl),
		})
	}
}
