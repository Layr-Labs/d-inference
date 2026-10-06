package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// shorterHitFixture is two checkpoint-mode machines at the same prefill rate
// with the benefit caps lifted, so the deeper checkpoint is a strict routing
// winner instead of a capped tie. Its retained indexes are read sequentially,
// after the real registry operations have completed.
type shorterHitFixture struct {
	r           *production.Registry
	p, q        *production.Provider
	capability  protocol.PrefixCacheV2Capability
	short, long protocol.PrefixCacheAnchor
	plan        production.CachePlan
	config      cachetracker.Config[*production.Provider]
	pricing     *checkpointPricingFixture
	admission   production.CacheReceiptAdmitter
}

func newShorterHitFixture(t *testing.T) *shorterHitFixture {
	t.Helper()
	f := &shorterHitFixture{}
	r, pricing := newCheckpointPricingFixture(t, production.Dependencies{Cache: production.CacheDependencies{
		Trackers: func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
			f.config = config
			return cachetracker.New(config)
		},
		ReceiptAdmissions: func(admission production.CacheReceiptAdmission) production.CacheReceiptAdmitter {
			f.admission = admission
			return admission
		},
	}})
	r.Disconnect("provider-a")
	checkpointPricingUncap(t, r)
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	f.r, f.pricing, f.capability = r, pricing, capability
	f.short, f.long = exactTestAnchor(8, "c"), exactTestAnchor(16, "d") // 2,048 and 4,096 tokens
	f.plan = pricing.plans.bind(exactTestPlan(f.short, f.long, exactTestAnchor(17, "e")))
	for _, id := range []string{"machine-p", "machine-q"} {
		provider := checkpointPricingProvider(t, r, id, capability)
		provider.Mu().Lock()
		provider.PrefillTPS = 1000
		provider.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
		provider.Mu().Unlock()
		if id == "machine-p" {
			f.p = provider
		} else {
			f.q = provider
		}
	}
	return f
}

// attempt prepares a real coordinator attempt and returns its receipt nonce.
func (f shorterHitFixture) attempt(t *testing.T, provider *production.Provider, id string, plan production.CachePlan) string {
	t.Helper()
	if !plan.HasOrigin() {
		plan = f.pricing.plans.bind(plan)
	}
	pr := &production.PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
	if err := f.r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	nonce := pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce
	if nonce == "" {
		t.Fatalf("attempt %s was not prepared", id)
	}
	return nonce
}

// lookup sends a miss, or a hit at the matched anchor when one is given.
func (f shorterHitFixture) lookup(
	t *testing.T, provider *production.Provider, id, nonce string, seq uint64, tier string,
	plan production.CachePlan, matched *protocol.PrefixCacheAnchor,
) production.CacheReceiptResult {
	t.Helper()
	lookup := fenceTestV2Lookup(nonce, f.capability, plan.Boundaries[len(plan.Boundaries)-1], seq)
	lookup.RequestID, lookup.Tier = id, tier
	if matched != nil {
		lookup.Outcome, lookup.MatchedAnchor = "hit", matched
		lookup.ExpectedPrefillTokensSaved, lookup.StageMs = matched.TokenCount, 50
	}
	if tier == "memory" {
		lookup.StageMs = 0
	}
	return f.r.ApplyPrefixCacheLookupV2Result(provider.ID, lookup)
}

// ready publishes the anchors on an attempt whose lookup was accepted.
func (f shorterHitFixture) ready(
	t *testing.T, provider *production.Provider, id, nonce string, seq uint64, tier string,
	anchors ...protocol.PrefixCacheAnchor,
) {
	t.Helper()
	ready := fenceTestV2Ready(nonce, f.capability, anchors[len(anchors)-1], seq)
	ready.RequestID, ready.Tier, ready.ReadyAnchors = id, tier, anchors
	ready.ExpectedPrefillTokensSaved = anchors[len(anchors)-1].TokenCount
	ready.StageMs = 100
	if tier == "memory" {
		ready.StageMs = 0
	}
	if got := f.r.ApplyPrefixCacheReadyV2Result(provider.ID, ready); !got.Accepted {
		t.Fatalf("%s ready = %+v", id, got)
	}
}

// donate runs a real miss + durable-ready exchange publishing the anchors.
func (f shorterHitFixture) donate(
	t *testing.T, provider *production.Provider, id string, seq uint64, tier string,
	plan production.CachePlan, anchors ...protocol.PrefixCacheAnchor,
) {
	t.Helper()
	nonce := f.attempt(t, provider, id, plan)
	if got := f.lookup(t, provider, id, nonce, seq, tier, plan, nil); !got.Accepted {
		t.Fatalf("%s donor lookup = %+v", id, got)
	}
	f.ready(t, provider, id, nonce, seq+1, tier, anchors...)
}

// hit sends a valid hit receipt matched at the given anchor of the plan.
func (f shorterHitFixture) hit(
	t *testing.T, provider *production.Provider, id string, seq uint64, tier string,
	plan production.CachePlan, matched protocol.PrefixCacheAnchor,
) production.CacheReceiptResult {
	t.Helper()
	return f.lookup(t, provider, id, f.attempt(t, provider, id, plan), seq, tier, plan, &matched)
}

func (f shorterHitFixture) holds(provider *production.Provider, plan production.CachePlan, anchor protocol.PrefixCacheAnchor, tier string) bool {
	key := cachetracker.CacheTierBoundaryKey(f.pricing.routeKey, plan, anchor, tier)
	_, ok := f.config.Holders.Bucket(key).Load(provider.ID)
	return ok
}

func (f shorterHitFixture) removed(reason cachetracker.RemovalReason) uint64 {
	return f.r.CacheRoutingLifecycleStatus().HolderRemoved[string(reason)]
}

func (f shorterHitFixture) reserve(t *testing.T, id string) (*production.Provider, production.RoutingDecision, *production.PendingRequest) {
	t.Helper()
	request := &production.PendingRequest{RequestID: id, Model: "model", CachePlan: f.plan,
		EstimatedPromptTokens: f.plan.PromptTokenCount, RequestedMaxTokens: 128}
	selected, decision := f.r.ReserveProviderEx("model", request)
	if selected == nil {
		t.Fatalf("no provider reserved: %+v", decision)
	}
	selected.RemovePending(request.RequestID)
	f.r.SetProviderIdle(selected.ID)
	return selected, decision, request
}
