package registry_test

import (
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type fenceTestClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFenceTestClock() *fenceTestClock {
	return &fenceTestClock{now: time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)}
}

func (c *fenceTestClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fenceTestClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

type fenceRegistry struct {
	*production.Registry
	plans     preparationFixture
	holders   *cacheindex.Holders[cachetracker.Holder[*production.Provider]]
	fences    *cacheindex.Records[cachetracker.FenceKey, cachetracker.FenceRecord]
	proofs    *cachetracker.Proofs
	admission production.CacheReceiptAdmitter
	query     production.CacheHintQuerier
	routeKey  []byte
}

// Keep holders alive across every fence window so expiry belongs to the fence.
func fenceTestRegistry(t *testing.T) (*fenceRegistry, *production.Provider, protocol.PrefixCacheV2Capability, *fenceTestClock) {
	t.Helper()
	clock := newFenceTestClock()
	f := &fenceRegistry{}
	deps := production.CacheDependencies{
		Now: clock.Now,
		Generations: func() *cacheplan.Generation {
			f.plans.generation = &cacheplan.Generation{}
			return f.plans.generation
		},
		Holders: func() *cacheindex.Holders[cachetracker.Holder[*production.Provider]] {
			f.holders = cacheindex.NewHolders[cachetracker.Holder[*production.Provider]]()
			return f.holders
		},
		Proofs: func(generation *cacheplan.Generation, records *cacheindex.Records[cachetracker.FenceKey, cachetracker.FenceRecord]) *cachetracker.Proofs {
			f.fences = records
			f.proofs = cachetracker.NewProofs(generation, records)
			return f.proofs
		},
		ReceiptAdmissions: func(admission production.CacheReceiptAdmission) production.CacheReceiptAdmitter {
			f.admission = admission
			return admission
		},
		HintQueries: func(query production.CacheHintQuery) production.CacheHintQuerier {
			f.query = query
			return query
		},
	}
	f.Registry = production.NewWithDependencies(testLogger(), production.Dependencies{Cache: deps})
	config := generationTestConfig(production.CacheRoutingOn)
	config.TTL, config.MaxHolders = 2*time.Hour, 8
	maxDiscount, maxFraction := 1000.0, .35
	config.MaxDiscountMs, config.MaxCostFraction = &maxDiscount, &maxFraction
	if err := f.ConfigureCacheRouting(config); err != nil {
		t.Fatal(err)
	}
	f.routeKey = cacheactivation.HMACBytes([]byte("0123456789abcdef0123456789abcdef"), []byte("darkbloom/cache-routing/route/v3"))
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	provider := f.Register("provider-a", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
	})
	return f, provider, capability, clock
}

func exactTestAnchor(blocks int, hexByte string) protocol.PrefixCacheAnchor {
	return protocol.PrefixCacheAnchor{TokenCount: blocks * int(promptcontract.BlockSize), ChainHash: strings.Repeat(hexByte, 64)}
}

func exactTestPlan(boundaries ...protocol.PrefixCacheAnchor) production.CachePlan {
	return production.CachePlan{ModelAggregateHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64),
		CacheScope: "opaque-scope", PromptTokenCount: boundaries[len(boundaries)-1].TokenCount, Boundaries: boundaries}
}

func fenceTestLookup(t *testing.T, r *fenceRegistry, provider *production.Provider, capability protocol.PrefixCacheV2Capability, id string, plan production.CachePlan, hash string, seq uint64) *protocol.PrefixCacheLookupV2Message {
	t.Helper()
	pr := &production.PendingRequest{RequestID: id, Model: "model", CachePlan: r.plans.bind(plan)}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	nonce := pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce
	if nonce == "" {
		t.Fatalf("attempt %s was not prepared", id)
	}
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	prompt.ChainHash = hash
	return &protocol.PrefixCacheLookupV2Message{
		RequestID: id, CacheReceiptNonce: nonce, ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: seq, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
}

func fenceTestCapabilityReason(r *fenceRegistry, provider *production.Provider) production.CacheReceiptReason {
	_, reason := r.admission.Admit(provider.ID, "model", "ssd")
	return reason
}

func fenceTestHints(r *fenceRegistry, plan production.CachePlan, now time.Time) map[string]production.CacheRoutingHint {
	if !plan.HasOrigin() {
		plan = r.plans.bind(plan)
	}
	hints, _ := r.query.Query("model", plan, r.routeKey, production.CacheRoutingOn, now)
	return hints
}

func fenceTestCheckpoint(t *testing.T, r *fenceRegistry, provider *production.Provider, capability protocol.PrefixCacheV2Capability, id string, plan production.CachePlan, sequence uint64) (*production.PendingRequest, *protocol.PrefixCacheReadyV2Message) {
	t.Helper()
	pr := &production.PendingRequest{RequestID: id, Model: "model", CachePlan: r.plans.bind(plan)}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	metadata := pr.CacheAttemptSnapshot().MetadataMessage()
	if metadata.CacheReceiptNonce == "" || metadata.CacheReceiptBoundaryMode != capability.ReadyBoundaryMode {
		t.Fatalf("checkpoint attempt lost negotiated mode: %+v", pr)
	}
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	lookup := fenceTestV2Lookup(metadata.CacheReceiptNonce, capability, prompt, sequence)
	lookup.RequestID = id
	if !r.ApplyPrefixCacheLookupV2(provider.ID, lookup) {
		t.Fatal("lookup rejected")
	}
	ready := fenceTestV2Ready(metadata.CacheReceiptNonce, capability, prompt, sequence+1)
	ready.RequestID = id
	return pr, ready
}

func fenceTestV2Lookup(nonce string, capability protocol.PrefixCacheV2Capability, prompt protocol.PrefixCacheAnchor, sequence uint64) *protocol.PrefixCacheLookupV2Message {
	return &protocol.PrefixCacheLookupV2Message{
		Type: protocol.TypePrefixCacheLookupV2, RequestID: "request-" + nonce, CacheReceiptNonce: nonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: sequence, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
}

func fenceTestV2Ready(nonce string, capability protocol.PrefixCacheV2Capability, prompt protocol.PrefixCacheAnchor, sequence uint64) *protocol.PrefixCacheReadyV2Message {
	return &protocol.PrefixCacheReadyV2Message{
		Type: protocol.TypePrefixCacheReadyV2, RequestID: "request-" + nonce, CacheReceiptNonce: nonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: sequence, Outcome: "ready", Tier: "ssd", ReadyAnchors: []protocol.PrefixCacheAnchor{prompt},
		ExpectedPrefillTokensSaved: prompt.TokenCount, StageMs: 2,
	}
}

func checkpointTestProvider(t *testing.T, r *fenceRegistry, id string, capability protocol.PrefixCacheV2Capability) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r.Registry, id, "model", 100)
	p.Mu().Lock()
	p.PrefillTPS = 100
	p.PrefixCacheProtocol = 2
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	p.Models[0].WeightHash = capability.ModelAggregateHash
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
	p.Mu().Unlock()
	return p
}
