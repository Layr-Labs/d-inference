package registry_test

import (
	"math/rand"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

type serviceCostLimits struct {
	maxDiscountMs, maxCostFraction *float64
}

type serviceCostCandidate struct {
	cachepolicy.ServiceCost
	provider     *production.Provider
	revision     *cachepeer.Revision
	evidence     forecast.Evidence
	firstContent forecast.Estimate
}

func serviceCostFixture(t testing.TB, prefillTPS float64, queue, pending int) (*serviceCostLimits, *serviceCostCandidate, production.CacheRoutingHint) {
	t.Helper()
	var plans preparationFixture
	var query production.CacheHintQuerier
	var revision *cachepeer.Revision
	r := production.NewWithDependencies(testLogger(), production.Dependencies{Cache: production.CacheDependencies{
		Generations: func() *cacheplan.Generation { plans.generation = &cacheplan.Generation{}; return plans.generation },
		Revisions:   func(string) *cachepeer.Revision { revision = cachepeer.NewRevision(); return revision },
		HintQueries: func(q production.CacheHintQuery) production.CacheHintQuerier { query = q; return q },
	}})
	config := generationTestConfig(production.CacheRoutingOn)
	config.TTL, config.MaxHolders = time.Minute, 8
	if err := r.ConfigureCacheRouting(config); err != nil {
		t.Fatal(err)
	}
	capability := checkpointPricingCapability(1)
	p := r.Register("warm", nil, &protocol.RegisterMessage{PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability}})
	plan := plans.bind(cacheFlowPlan(cacheFlowAnchor(16, "c")))
	request := &production.PendingRequest{RequestID: "donor", Model: "model", CachePlan: plan}
	if err := r.PrepareCacheAttempt(request, p); err != nil {
		t.Fatal(err)
	}
	metadata := request.CacheAttemptSnapshot().MetadataMessage()
	anchor := plan.Boundaries[0]
	if !r.ApplyPrefixCacheLookupV2(p.ID, &protocol.PrefixCacheLookupV2Message{
		Type: protocol.TypePrefixCacheLookupV2, RequestID: request.RequestID, CacheReceiptNonce: metadata.CacheReceiptNonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
		CacheEpoch: capability.CacheEpoch, CacheSeq: 1, PromptAnchor: anchor, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}) || !r.ApplyPrefixCacheReadyV2(p.ID, &protocol.PrefixCacheReadyV2Message{
		Type: protocol.TypePrefixCacheReadyV2, RequestID: request.RequestID, CacheReceiptNonce: metadata.CacheReceiptNonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
		CacheEpoch: capability.CacheEpoch, CacheSeq: 2, Outcome: "ready", Tier: "ssd", ReadyAnchors: []protocol.PrefixCacheAnchor{anchor},
		ExpectedPrefillTokensSaved: 4096, StageMs: 120,
	}) {
		t.Fatal("service-cost fixture receipt rejected")
	}
	routeKey := cacheactivation.HMACBytes([]byte("0123456789abcdef0123456789abcdef"), []byte("darkbloom/cache-routing/route/v3"))
	hints, _ := query.Query("model", plan, routeKey, production.CacheRoutingOn, time.Now())
	hint, ok := hints[p.ID]
	if !ok {
		t.Fatal("service-cost fixture has no authenticated endpoint")
	}
	// Restore the original exact pricing inputs after authenticating provenance.
	hint.EvidenceWeight, hint.ExpiresAt = 1, time.Now().Add(time.Minute)
	prefill := 10000 / prefillTPS * 1000
	c := &serviceCostCandidate{provider: p, revision: revision, ServiceCost: cachepolicy.ServiceCost{
		Rates: performance.Rates{StaticPrefill: prefillTPS, Occupancy: queue}, PricedPromptTokens: 10000, PrefillCostMs: prefill,
		Breakdown: cachepolicy.ServiceBreakdown{ThisReqMs: prefill + 2000, QueueMs: float64(queue) * 3000,
			PendingMs: float64(pending) * 750}},
		// The original snapshot has queue rows with an unknown prompt length,
		// no load penalty for its empty slot state, and no measured decode rate.
		evidence: forecast.Evidence{DecodeTPS: 1, Workload: forecast.Workload{PrefillAhead: float64(queue) * 10000}},
	}
	c.CostMs = c.Breakdown.ThisReqMs + c.Breakdown.QueueMs + c.Breakdown.PendingMs
	c.Breakdown.Total = c.CostMs
	return &serviceCostLimits{}, c, hint
}

func applyServiceHint(limits *serviceCostLimits, c *serviceCostCandidate, hint production.CacheRoutingHint) {
	c.provider.Mu().Lock()
	c.ServiceCost = hint.PriceForProviderLocked(c.provider, "model", c.ServiceCost, limits.maxDiscountMs, limits.maxCostFraction)
	c.provider.Mu().Unlock()
	now := time.Now()
	request := forecast.Request{PromptTokens: c.PricedPromptTokens, UpperBoundTokens: c.PricedPromptTokens,
		Incoming: performance.IncomingWork{RequestedMaxTokens: 128}}
	c.ForecastCache.Apply(&request, now)
	evidence := c.evidence
	evidence.PrefillTPS = c.Rates.Prefill()
	c.firstContent = forecast.Evaluate(&evidence, request, now).Estimate
}

func serviceColdCandidate(id string, cost float64, queue, pending int, discount float64) *serviceCostCandidate {
	return &serviceCostCandidate{provider: &production.Provider{ID: id},
		ServiceCost: cachepolicy.ServiceCost{CostMs: cost, EstimatedTTFTSavedMs: discount,
			Breakdown: cachepolicy.ServiceBreakdown{CacheDiscountMs: discount, Total: cost}},
		firstContent: forecast.Estimate{Status: forecast.Unknown, ExpectedMs: cost, ServiceMs: float64(queue+pending) * 1000, CachedTokens: discount}}
}

func selectServiceCandidate(pool []*serviceCostCandidate) (winner, runnerUp *serviceCostCandidate, near int, path production.SelectionPath) {
	decision := selection.Select(pool, func(c *serviceCostCandidate) selection.Candidate {
		return selection.Project(c.provider.ID, &c.firstContent, &c.Breakdown, c.EstimatedTTFTSavedMs, c.EvidenceWeight, false)
	}, rand.Intn, "")
	if decision.Winner >= 0 {
		winner = pool[decision.Winner]
	}
	if decision.RunnerUp >= 0 {
		runnerUp = pool[decision.RunnerUp]
	}
	return winner, runnerUp, decision.NearTieSize, production.SelectionPath(decision.Path)
}
