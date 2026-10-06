package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type checkpointPricingFixture struct {
	plans    preparationFixture
	query    production.CacheHintQuerier
	routeKey []byte
}

func newCheckpointPricingFixture(t *testing.T, dependencies ...production.Dependencies) (*production.Registry, *checkpointPricingFixture) {
	t.Helper()
	f := &checkpointPricingFixture{
		routeKey: cacheactivation.HMACBytes([]byte("0123456789abcdef0123456789abcdef"), []byte("darkbloom/cache-routing/route/v3")),
	}
	var deps production.Dependencies
	if len(dependencies) != 0 {
		deps = dependencies[0]
	}
	deps.Cache.Generations = func() *cacheplan.Generation {
		f.plans.generation = &cacheplan.Generation{}
		return f.plans.generation
	}
	deps.Cache.HintQueries = func(query production.CacheHintQuery) production.CacheHintQuerier {
		f.query = query
		return query
	}
	r, _, _ := exactTestRegistry(t, deps)
	return r, f
}

func (f *checkpointPricingFixture) hints(plan production.CachePlan, now time.Time) map[string]production.CacheRoutingHint {
	if !plan.HasOrigin() {
		plan = f.plans.bind(plan)
	}
	hints, _ := f.query.Query("model", plan, f.routeKey, production.CacheRoutingOn, now)
	return hints
}

func checkpointPricingUncap(t *testing.T, r *production.Registry) {
	t.Helper()
	config := generationTestConfig(production.CacheRoutingOn)
	config.TTL, config.MaxHolders = time.Minute, 8
	if err := r.ConfigureCacheRouting(config); err != nil {
		t.Fatal(err)
	}
}

func checkpointPricingCapability(index int) protocol.PrefixCacheV2Capability {
	capability := exactTestCapability(fmt.Sprintf("%08x-1111-1111-1111-111111111111", index+1))
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	return capability
}

func checkpointPricingProvider(t *testing.T, r *production.Registry, id string, capability protocol.PrefixCacheV2Capability) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, id, "model", 100)
	p.Mu().Lock()
	p.PrefillTPS = 100
	p.PrefixCacheProtocol = 2
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	p.Models[0].WeightHash = capability.ModelAggregateHash
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
	p.Mu().Unlock()
	return p
}

func checkpointPricingAttempt(t *testing.T, r *production.Registry, p *production.Provider, capability protocol.PrefixCacheV2Capability, id string, plan production.CachePlan, sequence uint64) (*production.PendingRequest, *protocol.PrefixCacheReadyV2Message) {
	t.Helper()
	pr := &production.PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
	if err := r.PrepareCacheAttempt(pr, p); err != nil {
		t.Fatal(err)
	}
	metadata := pr.CacheAttemptSnapshot().MetadataMessage()
	if metadata.CacheReceiptNonce == "" || metadata.CacheReceiptBoundaryMode != capability.ReadyBoundaryMode {
		t.Fatalf("checkpoint attempt lost negotiated mode: %+v", pr)
	}
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	lookup := &protocol.PrefixCacheLookupV2Message{
		Type: protocol.TypePrefixCacheLookupV2, RequestID: id, CacheReceiptNonce: metadata.CacheReceiptNonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: sequence, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !r.ApplyPrefixCacheLookupV2(p.ID, lookup) {
		t.Fatal("lookup rejected")
	}
	ready := &protocol.PrefixCacheReadyV2Message{
		Type: protocol.TypePrefixCacheReadyV2, RequestID: id, CacheReceiptNonce: metadata.CacheReceiptNonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: sequence + 1, Outcome: "ready", Tier: "ssd", ReadyAnchors: []protocol.PrefixCacheAnchor{prompt},
		ExpectedPrefillTokensSaved: prompt.TokenCount, StageMs: 2,
	}
	return pr, ready
}

func checkpointPricingFreshIdle(p *production.Provider, history *measurements.History, rate float64) {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	now := time.Now()
	p.CapacityAcceptedAt = now
	p.PrefillTPS = rate
	slot := &p.BackendCapacity.Slots[0]
	slot.State = "idle"
	slot.ObservedPrefillTPS = rate
	slot.ObservedDecodeTPS = 100
	slot.Telemetry = &protocol.SlotTelemetry{
		QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64),
		IsolatedPrefillTPS: &rate, EWMAInitialized: new(bool),
	}
	*slot.Telemetry.EWMAInitialized = true
	slot.PerformanceMeasurements = localRateMeasurements(rate, slot.ObservedDecodeTPS)
	// Local evidence has no transport handoff, matching the original fixture.
	history.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, 0)
}
