package registry_test

import (
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type preparationFixture struct {
	mu         sync.Mutex
	generation *cacheplan.Generation
	attempts   *cacheindex.Records[string, cachetracker.Attempt[*production.Provider]]
	revision   *cachepeer.Revision
}

func newPreparationFixture(t *testing.T, inputs ...production.CacheDependencies) (*production.Registry, *production.Provider, *preparationFixture) {
	t.Helper()
	f := &preparationFixture{}
	var deps production.CacheDependencies
	if len(inputs) != 0 {
		deps = inputs[0]
	}
	deps.Generations = func() *cacheplan.Generation {
		generation := &cacheplan.Generation{}
		f.mu.Lock()
		f.generation = generation
		f.mu.Unlock()
		return generation
	}
	deps.Attempts = func() *cacheindex.Records[string, cachetracker.Attempt[*production.Provider]] {
		attempts := cacheindex.NewRecords[string, cachetracker.Attempt[*production.Provider]]()
		f.mu.Lock()
		f.attempts = attempts
		f.mu.Unlock()
		return attempts
	}
	deps.Revisions = func(string) *cachepeer.Revision {
		revision := cachepeer.NewRevision()
		f.mu.Lock()
		f.revision = revision
		f.mu.Unlock()
		return revision
	}
	r, p, _ := exactTestRegistry(t, production.Dependencies{Cache: deps})
	return r, p, f
}

type deferredCachePublication func() bool

func (publish deferredCachePublication) Publish() bool { return publish() }

func preparationReady(t *testing.T, r *production.Registry, p *production.Provider, f *preparationFixture) (*production.PendingRequest, *protocol.PrefixCacheReadyV2Message) {
	t.Helper()
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	plan := preparationPlan()
	pr := &production.PendingRequest{RequestID: "completed", Model: "model", CachePlan: f.bind(plan)}
	if err := r.PrepareCacheAttempt(pr, p); err != nil {
		t.Fatal(err)
	}
	metadata := pr.CacheAttemptSnapshot().MetadataMessage()
	if metadata.CacheReceiptNonce == "" || metadata.CacheReceiptBoundaryMode != capability.ReadyBoundaryMode {
		t.Fatalf("checkpoint attempt lost negotiated mode: %+v", pr)
	}
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	lookup := &protocol.PrefixCacheLookupV2Message{
		Type: protocol.TypePrefixCacheLookupV2, RequestID: pr.RequestID, CacheReceiptNonce: metadata.CacheReceiptNonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
		CacheEpoch: capability.CacheEpoch, CacheSeq: 1, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !r.ApplyPrefixCacheLookupV2(p.ID, lookup) {
		t.Fatal("lookup rejected")
	}
	ready := &protocol.PrefixCacheReadyV2Message{
		Type: protocol.TypePrefixCacheReadyV2, RequestID: pr.RequestID, CacheReceiptNonce: metadata.CacheReceiptNonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
		CacheEpoch: capability.CacheEpoch, CacheSeq: 2, Outcome: "ready", Tier: "ssd", ReadyAnchors: []protocol.PrefixCacheAnchor{prompt},
		ExpectedPrefillTokensSaved: prompt.TokenCount, StageMs: 2,
	}
	return pr, ready
}

func preparationPlan() production.CachePlan {
	return production.CachePlan{
		ModelAggregateHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64),
		CacheScope: "opaque-scope", PromptTokenCount: 16 * int(promptcontract.BlockSize),
		Boundaries: []protocol.PrefixCacheAnchor{{TokenCount: 16 * int(promptcontract.BlockSize), ChainHash: strings.Repeat("c", 64)}},
	}
}

func (f *preparationFixture) bind(plan production.CachePlan) production.CachePlan {
	f.mu.Lock()
	generation := f.generation
	f.mu.Unlock()
	sidecar := promptcontract.Plan{Participating: true, PromptTokenCount: uint32(plan.PromptTokenCount)}
	for _, boundary := range plan.Boundaries {
		sidecar.BlockBoundaries = append(sidecar.BlockBoundaries, promptcontract.Boundary{TokenCount: uint32(boundary.TokenCount), ChainHash: boundary.ChainHash})
	}
	bound, accepted := cacheplan.PlanFromSidecar(generation, cacheplan.Identity{
		ModelAggregateHash: plan.ModelAggregateHash, PromptContractID: plan.PromptContractID, CacheScope: plan.CacheScope,
	}, sidecar)
	if accepted {
		bound.RepeatedPrefixTokens = plan.RepeatedPrefixTokens
		plan = bound
	}
	return plan
}

func assertOrdinaryCacheFrame(t *testing.T, snapshot production.CacheAttemptSnapshot) {
	t.Helper()
	staleRepeat := 512
	message := protocol.InferenceRequestMessage{CacheReceiptNonce: "old", CacheScope: "old", PrefixCacheProtocol: 2, CacheReceiptBoundaryMode: "old", CacheRepeatedPrefixTokens: &staleRepeat}
	snapshot.ApplyTo(&message)
	if message.CacheReceiptNonce != "" || message.CacheScope != "" || message.PrefixCacheProtocol != 0 || message.CacheReceiptBoundaryMode != "" || message.CacheRepeatedPrefixTokens != nil {
		t.Fatalf("revoked attempt leaked cache metadata: %+v", message)
	}
}
