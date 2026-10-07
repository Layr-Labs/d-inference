package registry_test

import (
	"encoding/json"
	"fmt"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// The harness retains the actual constructor dependencies. Receipt preparation,
// admission and retirement still run through the serialized registry path.
type cacheSizingHarness struct {
	tb              testing.TB
	r               *production.Registry
	provider        *production.Provider
	capability      protocol.PrefixCacheV2Capability
	clock           *fenceTestClock
	seq             uint64
	tracker         *cacheIndexKernelFixture
	demand          *cachedemand.Tracker
	demandIndex     *cachehistory.Index
	demandLimit     int
	demandTTL       time.Duration
	routeKey        []byte
	query           production.CacheHintQuery
	forgetAttempts  bool
	decodedReceipts bool
}

func newCacheSizingHarness(tb testing.TB, ttl time.Duration, options ...production.CacheDependencies) *cacheSizingHarness {
	tb.Helper()
	h := &cacheSizingHarness{tb: tb, clock: newFenceTestClock()}
	var deps production.CacheDependencies
	if len(options) != 0 {
		deps = options[0]
	}
	deps.Now = h.clock.Now
	deps.HintQueries = func(query production.CacheHintQuery) production.CacheHintQuerier {
		h.query = query
		return query
	}
	deps.Trackers = func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
		h.tracker = &cacheIndexKernelFixture{Tracker: cachetracker.New(config), config: config}
		return h.tracker.Tracker
	}
	deps.Demand = func(limit int, ttl time.Duration, index *cachehistory.Index) *cachedemand.Tracker {
		h.demandLimit, h.demandTTL, h.demandIndex = limit, ttl, index
		h.demand = cachedemand.New(limit, ttl, index)
		return h.demand
	}
	h.r = production.NewWithDependencies(testLogger(), production.Dependencies{Cache: deps})
	config := generationTestConfig(production.CacheRoutingOn)
	config.TTL, config.MaxHolders = ttl, indexKernelMaxHolders
	if err := h.r.ConfigureCacheRouting(config); err != nil {
		tb.Fatal(err)
	}
	h.routeKey = cacheactivation.HMACBytes([]byte("0123456789abcdef0123456789abcdef"), []byte("darkbloom/cache-routing/route/v3"))
	h.capability = exactTestCapability("11111111-1111-1111-1111-111111111111")
	h.provider = h.r.Register("0f6b3c1e-5a0d-4c58-9f7e-2b1d6a4c8e90", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{h.capability},
	})
	return h
}

func cacheSizingAnchor(index int) protocol.PrefixCacheAnchor {
	return protocol.PrefixCacheAnchor{TokenCount: int(promptcontract.BlockSize), ChainHash: fmt.Sprintf("%064x", index+1)}
}

func (h *cacheSizingHarness) plan(index int) production.CachePlan {
	return bindDemandPlan(h.tracker.config.Generation, exactTestPlan(cacheSizingAnchor(index)))
}

func (h *cacheSizingHarness) donate(index int) production.CachePlan { return h.receipt(index, false) }
func (h *cacheSizingHarness) hit(index int) production.CachePlan    { return h.receipt(index, true) }

func (h *cacheSizingHarness) frame(lookup *protocol.PrefixCacheLookupV2Message, ready *protocol.PrefixCacheReadyV2Message) (*protocol.PrefixCacheLookupV2Message, *protocol.PrefixCacheReadyV2Message) {
	if !h.decodedReceipts {
		return lookup, ready
	}
	if lookup != nil {
		lookup = sizingWireCopy(h.tb, lookup)
	}
	if ready != nil {
		ready = sizingWireCopy(h.tb, ready)
	}
	return lookup, ready
}

func (h *cacheSizingHarness) receipt(index int, hit bool) production.CachePlan {
	h.tb.Helper()
	plan := h.plan(index)
	anchor := plan.Boundaries[0]
	id := "request-" + strconv.Itoa(index) + "-" + strconv.FormatUint(h.seq, 10)
	pr := &production.PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
	if err := h.r.PrepareCacheAttempt(pr, h.provider); err != nil {
		h.tb.Fatal(err)
	}
	nonce := pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce
	if nonce == "" {
		h.tb.Fatalf("attempt %s was not prepared", id)
	}
	h.seq++
	lookup := fenceTestV2Lookup(nonce, h.capability, anchor, h.seq)
	lookup.RequestID = id
	if hit {
		lookup.Outcome, lookup.MatchedAnchor = "hit", &anchor
		lookup.ExpectedPrefillTokensSaved, lookup.StageMs = anchor.TokenCount, 120
	}
	lookup, _ = h.frame(lookup, nil)
	if result := h.r.ApplyPrefixCacheLookupV2Result(h.provider.ID, lookup); !result.Accepted {
		h.tb.Fatalf("lookup %s rejected: %s", id, result.Reason)
	}
	if !hit {
		h.seq++
		ready := fenceTestV2Ready(nonce, h.capability, anchor, h.seq)
		ready.RequestID = id
		_, ready = h.frame(nil, ready)
		if result := h.r.ApplyPrefixCacheReadyV2Result(h.provider.ID, ready); !result.Accepted {
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

// The retained query keeps the original digest-before-lock ordering and returns
// the same holder metadata as the controller's content-only routing stage.
func (h *cacheSizingHarness) matches(plan production.CachePlan, now time.Time) []cachetracker.Match[*production.Provider] {
	return h.query.MatchBoundaries(plan, h.routeKey, production.CacheRoutingOn, now)
}

func (h *cacheSizingHarness) removed(reason cachetracker.RemovalReason) uint64 {
	return h.r.CacheRoutingLifecycleStatus().HolderRemoved[string(reason)]
}

func sizingWireCopy[T any](tb testing.TB, message *T) *T {
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
