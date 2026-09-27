package registry

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// shorterHitFixture is two checkpoint-mode machines at the same prefill rate
// with the benefit caps lifted, so the deeper checkpoint is a strict routing
// winner instead of a capped tie.
type shorterHitFixture struct {
	r           *Registry
	p, q        *Provider
	capability  protocol.PrefixCacheV2Capability
	short, long protocol.PrefixCacheAnchor
	plan        CachePlan
}

func newShorterHitFixture(t *testing.T) shorterHitFixture {
	t.Helper()
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	r.cacheRoutingMaxDiscountMs, r.cacheRoutingMaxCostFraction = nil, nil
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	f := shorterHitFixture{r: r, capability: capability,
		short: exactTestAnchor(8, "c"), long: exactTestAnchor(16, "d")} // 2,048 and 4,096 tokens
	f.plan = boundTestCachePlan(r, exactTestPlan(f.short, f.long, exactTestAnchor(17, "e")))
	for _, id := range []string{"machine-p", "machine-q"} {
		provider := checkpointTestProvider(t, r, id, capability)
		provider.mu.Lock()
		provider.PrefillTPS = 1000
		provider.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
		provider.mu.Unlock()
		if id == "machine-p" {
			f.p = provider
		} else {
			f.q = provider
		}
	}
	return f
}

// attempt prepares a real coordinator attempt and returns its receipt nonce.
func (f shorterHitFixture) attempt(t *testing.T, provider *Provider, id string, plan CachePlan) string {
	t.Helper()
	pr := &PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
	if err := prepareBoundTestCacheAttempt(f.r, pr, provider); err != nil {
		t.Fatal(err)
	}
	nonce := preparedTestCacheMetadata(pr).CacheReceiptNonce
	if nonce == "" {
		t.Fatalf("attempt %s was not prepared", id)
	}
	return nonce
}

// lookup sends a miss, or a hit at the matched anchor when one is given.
func (f shorterHitFixture) lookup(
	t *testing.T, provider *Provider, id, nonce string, seq uint64, tier string,
	plan CachePlan, matched *protocol.PrefixCacheAnchor,
) CacheReceiptResult {
	t.Helper()
	lookup := testV2Lookup(nonce, f.capability, plan.Boundaries[len(plan.Boundaries)-1], seq)
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
	t *testing.T, provider *Provider, id, nonce string, seq uint64, tier string,
	anchors ...protocol.PrefixCacheAnchor,
) {
	t.Helper()
	ready := testV2Ready(nonce, f.capability, anchors[len(anchors)-1], seq)
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
	t *testing.T, provider *Provider, id string, seq uint64, tier string,
	plan CachePlan, anchors ...protocol.PrefixCacheAnchor,
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
	t *testing.T, provider *Provider, id string, seq uint64, tier string,
	plan CachePlan, matched protocol.PrefixCacheAnchor,
) CacheReceiptResult {
	t.Helper()
	return f.lookup(t, provider, id, f.attempt(t, provider, id, plan), seq, tier, plan, &matched)
}

func (f shorterHitFixture) holds(provider *Provider, plan CachePlan, anchor protocol.PrefixCacheAnchor, tier string) bool {
	key := cacheTierBoundaryKey(f.r.cacheRouteKeys.route, plan, anchor, tier)
	f.r.cacheRouting.mu.Lock()
	defer f.r.cacheRouting.mu.Unlock()
	_, ok := f.r.cacheRouting.holders[key][provider.ID]
	return ok
}

func (f shorterHitFixture) removed(reason cacheHolderRemovalReason) uint64 {
	return f.r.CacheRoutingLifecycleStatus().HolderRemoved[string(reason)]
}

func (f shorterHitFixture) reserve(t *testing.T, id string) (*Provider, RoutingDecision, *PendingRequest) {
	t.Helper()
	request := &PendingRequest{RequestID: id, Model: "model", CachePlan: f.plan,
		EstimatedPromptTokens: f.plan.PromptTokenCount, RequestedMaxTokens: 128}
	selected, decision := f.r.ReserveProviderEx("model", request)
	if selected == nil {
		t.Fatalf("no provider reserved: %+v", decision)
	}
	selected.RemovePending(request.RequestID)
	f.r.SetProviderIdle(selected.ID)
	return selected, decision, request
}

// P held checkpoints at 2,048 and 4,096 and evicted the 4,096 file without
// rotating its epoch. Its next lookup is a valid hit at 2,048; no miss ever
// fires. The stale 4,096 holder must go for P only, and the scheduler must
// price P with the 2,048 saving it will actually deliver.
func TestShorterHitSupersedesDeeperHolderForThatProviderOnly(t *testing.T) {
	f := newShorterHitFixture(t)
	f.donate(t, f.p, "donor-p", 1, "ssd", f.plan, f.short, f.long)
	f.donate(t, f.q, "donor-q", 1, "ssd", f.plan, f.long)
	before := memoryTestHints(f.r, f.plan, time.Now())
	if before[f.p.ID].CachedTokens != f.long.TokenCount || before[f.q.ID].CachedTokens != f.long.TokenCount {
		t.Fatalf("positive control: both machines should advertise 4,096: %+v", before)
	}

	if got := f.hit(t, f.p, "repeat-p", 3, "ssd", f.plan, f.short); !got.Accepted || got.mismatch {
		t.Fatalf("valid shorter hit = %+v", got)
	}

	if f.holds(f.p, f.plan, f.long, "ssd") {
		t.Fatal("P kept its 4,096 holder after proving only 2,048")
	}
	if !f.holds(f.p, f.plan, f.short, "ssd") {
		t.Fatal("P lost the 2,048 holder its hit just proved")
	}
	if !f.holds(f.q, f.plan, f.long, "ssd") {
		t.Fatal("P's shorter hit removed Q's 4,096 holder")
	}
	status := f.r.CacheRoutingLifecycleStatus()
	if status.HolderRemoved[string(cacheHolderRemovalShorterHit)] != 1 ||
		status.HolderRemoved[string(cacheHolderRemovalMissInvalidation)] != 0 ||
		status.HolderRemoved[string(cacheHolderRemovalProofMismatch)] != 0 {
		t.Fatalf("removal accounting = %+v", status.HolderRemoved)
	}
	if f.r.cacheRouting.holderCount != 2 {
		t.Fatalf("holders = %d, want P@2,048 and Q@4,096", f.r.cacheRouting.holderCount)
	}

	// Never a fence, and the revision-free path leaves the capability usable.
	if status.FencesApplied != 0 || status.FencedCapabilities != 0 {
		t.Fatalf("shorter hit fenced the capability: %+v", status)
	}
	if _, reason := f.r.currentPrefixCacheV2CapabilityResult(f.p.ID, "model", "ssd"); reason != CacheReceiptAccepted {
		t.Fatalf("P capability = %s, want accepted", reason)
	}

	// The replay watermark is the hit's own sequence, untouched by removal.
	sequence := cacheV2SequenceKey{ProviderID: f.p.ID, ModelID: "model", CacheEpoch: f.capability.CacheEpoch, Tier: "ssd"}
	f.r.cacheRouting.mu.Lock()
	watermark := f.r.cacheRouting.v2Sequences[sequence]
	f.r.cacheRouting.mu.Unlock()
	if watermark != 3 {
		t.Fatalf("sequence watermark = %d, want 3", watermark)
	}
	if got := f.hit(t, f.p, "replay-p", 3, "ssd", f.plan, f.short); got.Reason != CacheReceiptSequence {
		t.Fatalf("replayed sequence = %+v, want %s", got, CacheReceiptSequence)
	}

	// The next hint credits P with what it proved, and Q with what it holds.
	hints := memoryTestHints(f.r, f.plan, time.Now())
	if hint := hints[f.p.ID]; hint.CachedTokens != f.short.TokenCount ||
		hint.PrefillTokensSaved != f.short.TokenCount || hint.StageMs != 50 || hint.Tier != "ssd" {
		t.Fatalf("P hint = %+v, want the 2,048 boundary at its measured stage cost", hint)
	}
	if hint := hints[f.q.ID]; hint.CachedTokens != f.long.TokenCount {
		t.Fatalf("Q hint = %+v, want 4,096", hint)
	}

	// 4,096 tokens at 1,000 tok/s less a 100 ms stage ≈ 3,996 ms; small
	// receipt-age decay is allowed.
	selected, decision, _ := f.reserve(t, "prefers-q")
	if selected != f.q || decision.CacheTier != "ssd" ||
		decision.CacheEstimatedTTFTSavedMs < 3980 || decision.CacheEstimatedTTFTSavedMs > 3996 {
		t.Fatalf("true 4,096 holder was not preferred: provider=%s decision=%+v", selected.ID, decision)
	}

	// With Q gone P still serves, priced at 2,048 tokens less its measured
	// 50 ms stage ≈ 1,998 ms, not the 3,996 ms the stale holder claimed.
	f.r.cacheRouting.disconnect(f.q.ID, cacheHolderRemovalDisconnect)
	removeTestProvider(f.r, f.q.ID)
	selected, decision, request := f.reserve(t, "only-p")
	if selected != f.p || decision.CacheTier != "ssd" ||
		decision.CacheEstimatedTTFTSavedMs < 1990 || decision.CacheEstimatedTTFTSavedMs > 1998 {
		t.Fatalf("P was not priced at the boundary it delivers: provider=%s decision=%+v", selected.ID, decision)
	}
	if request.CacheSelectionEstimatedTTFTSavedMs != decision.CacheEstimatedTTFTSavedMs || !request.CacheSelectionSelected {
		t.Fatalf("selection telemetry diverged from the decision: request=%v decision=%v",
			request.CacheSelectionEstimatedTTFTSavedMs, decision.CacheEstimatedTTFTSavedMs)
	}
}

// Removal is advisory. The request that hit at 2,048 prefills the rest and
// publishes 4,096 again; that ready re-teaches the boundary.
func TestShorterHitRemovalIsRetaughtByLaterReady(t *testing.T) {
	f := newShorterHitFixture(t)
	f.donate(t, f.p, "donor", 1, "ssd", f.plan, f.short, f.long)
	nonce := f.attempt(t, f.p, "repeat", f.plan)
	if got := f.lookup(t, f.p, "repeat", nonce, 3, "ssd", f.plan, &f.short); !got.Accepted {
		t.Fatalf("shorter hit = %+v", got)
	}
	if f.holds(f.p, f.plan, f.long, "ssd") {
		t.Fatal("deeper holder survived the shorter hit")
	}
	if got := memoryTestHints(f.r, f.plan, time.Now())[f.p.ID].CachedTokens; got != f.short.TokenCount {
		t.Fatalf("hint after the shorter hit = %d tokens, want 2,048", got)
	}
	f.ready(t, f.p, "repeat", nonce, 4, "ssd", f.long)
	if !f.holds(f.p, f.plan, f.long, "ssd") || !f.holds(f.p, f.plan, f.short, "ssd") {
		t.Fatal("a later ready did not re-teach the deeper boundary")
	}
	if got := memoryTestHints(f.r, f.plan, time.Now())[f.p.ID].CachedTokens; got != f.long.TokenCount {
		t.Fatalf("re-taught hint = %d tokens, want 4,096", got)
	}
	if got := f.removed(cacheHolderRemovalShorterHit); got != 1 {
		t.Fatalf("shorter_hit removals = %d, want 1", got)
	}
}

// Only the receipt's tier is touched: a resident hit says nothing about the
// durable store, and complete-checkpoint engines report a resident win as
// tier memory even when SSD staged a deeper run.
func TestShorterHitLeavesTheOtherTier(t *testing.T) {
	f := newShorterHitFixture(t)
	f.p.mu.Lock()
	f.p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": f.capability}
	f.p.mu.Unlock()
	f.donate(t, f.p, "ssd-donor", 1, "ssd", f.plan, f.short, f.long)
	f.donate(t, f.p, "memory-donor", 1, "memory", f.plan, f.short, f.long)

	if got := f.hit(t, f.p, "resident-repeat", 3, "memory", f.plan, f.short); !got.Accepted {
		t.Fatalf("resident shorter hit = %+v", got)
	}
	if f.holds(f.p, f.plan, f.long, "memory") {
		t.Fatal("resident 4,096 holder survived a resident hit at 2,048")
	}
	if !f.holds(f.p, f.plan, f.long, "ssd") || !f.holds(f.p, f.plan, f.short, "ssd") {
		t.Fatal("a resident hit removed durable evidence")
	}
	if !f.holds(f.p, f.plan, f.short, "memory") {
		t.Fatal("resident hit lost the boundary it proved")
	}
	if got := f.removed(cacheHolderRemovalShorterHit); got != 1 {
		t.Fatalf("shorter_hit removals = %d, want 1", got)
	}
}

// Nothing is removed when the hit is the deepest boundary the provider is
// recorded at, or when the deeper holder belongs to another continuation.
func TestShorterHitRemovesNothingWithoutADeeperHolderOnThisPrompt(t *testing.T) {
	f := newShorterHitFixture(t)
	f.donate(t, f.p, "donor", 1, "ssd", f.plan, f.short, f.long)

	if got := f.hit(t, f.p, "deepest", 3, "ssd", f.plan, f.long); !got.Accepted {
		t.Fatalf("hit at the deepest held boundary = %+v", got)
	}
	if !f.holds(f.p, f.plan, f.long, "ssd") || !f.holds(f.p, f.plan, f.short, "ssd") {
		t.Fatal("hit at the deepest boundary removed a holder")
	}

	// Same first 2,048 tokens, different continuation: its 4,096 boundary
	// has another chain hash, so P's original 4,096 holder is not in this plan.
	diverged := boundTestCachePlan(f.r, exactTestPlan(
		f.short, exactTestAnchor(16, "9"), exactTestAnchor(17, "8")))
	if got := f.hit(t, f.p, "diverged", 4, "ssd", diverged, f.short); !got.Accepted {
		t.Fatalf("hit on a diverging prompt = %+v", got)
	}
	if !f.holds(f.p, f.plan, f.long, "ssd") {
		t.Fatal("a diverging prompt's shorter hit removed another continuation's holder")
	}
	if got := f.removed(cacheHolderRemovalShorterHit); got != 0 {
		t.Fatalf("shorter_hit removals = %d, want 0", got)
	}
}

// Outcomes that are not a hit never supersede: a skip means the provider did
// not try, and a mismatch takes the fence path with its own accounting.
func TestOnlyAnAcceptedHitSupersedes(t *testing.T) {
	for _, outcome := range []string{"skipped_capacity", "skipped_cost", "skipped_policy"} {
		t.Run(outcome, func(t *testing.T) {
			f := newShorterHitFixture(t)
			f.donate(t, f.p, "donor", 1, "ssd", f.plan, f.short, f.long)
			prompt := f.plan.Boundaries[len(f.plan.Boundaries)-1]
			lookup := testV2Lookup(f.attempt(t, f.p, "skip", f.plan), f.capability, prompt, 3)
			lookup.RequestID, lookup.Outcome = "skip", outcome
			if got := f.r.ApplyPrefixCacheLookupV2Result(f.p.ID, lookup); !got.Accepted {
				t.Fatalf("%s = %+v", outcome, got)
			}
			if !f.holds(f.p, f.plan, f.long, "ssd") || f.removed(cacheHolderRemovalShorterHit) != 0 {
				t.Fatalf("%s removed a holder", outcome)
			}
		})
	}
	t.Run("matched anchor mismatch", func(t *testing.T) {
		f := newShorterHitFixture(t)
		f.donate(t, f.p, "donor", 1, "ssd", f.plan, f.short, f.long)
		forged := f.short
		forged.ChainHash = strings.Repeat("9", 64)
		if got := f.hit(t, f.p, "forged", 3, "ssd", f.plan, forged); got.Reason != CacheReceiptMatchedMismatch {
			t.Fatalf("forged matched anchor = %+v", got)
		}
		status := f.r.CacheRoutingLifecycleStatus()
		if status.HolderRemoved[string(cacheHolderRemovalShorterHit)] != 0 || status.FencesApplied != 1 {
			t.Fatalf("mismatch took the shorter-hit path: %+v", status)
		}
	})
}
