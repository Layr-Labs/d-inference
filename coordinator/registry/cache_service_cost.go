package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
)

// applyCacheHintLocked prices the provider-aligned endpoint with the same
// candidate snapshot as the base score. Caller holds provider.mu and r.mu.
func (r *Registry) applyCacheHintLocked(hint cacheRoutingHint, model string, candidate *routingCandidate) {
	snapshot := &candidate.snapshot
	priced := hint.PriceForProviderLocked(candidate.provider, model, cachepolicy.ServiceCost{
		Rates: performance.Rates{Profile: (*performance.Profile)(snapshot.performanceProfile), StaticPrefill: snapshot.prefillTPS,
			ObservedPrefill: snapshot.observedPrefillTPS, Occupancy: snapshotOccupancy(snapshot)},
		PricedPromptTokens: candidate.pricedPromptTokens, PrefillCostMs: candidate.prefillCostMs,
		CostMs: candidate.costMs, Breakdown: candidate.breakdown, Tier: candidate.cacheTier,
		EstimatedTTFTSavedMs: candidate.cacheEstimatedTTFTSavedMs, EvidenceWeight: candidate.cacheEvidenceWeight,
		ForecastCache: forecast.CacheBenefit{Tokens: candidate.firstContentCachedTokens, Weight: candidate.firstContentCacheWeight,
			RestoreMS: candidate.firstContentRestoreMs, ExpiresAt: candidate.firstContentCacheExpiresAt},
	}, r.cacheRoutingMaxDiscountMs, r.cacheRoutingMaxCostFraction)
	candidate.costMs, candidate.breakdown = priced.CostMs, priced.Breakdown
	candidate.cacheTier, candidate.cacheEstimatedTTFTSavedMs, candidate.cacheEvidenceWeight = priced.Tier, priced.EstimatedTTFTSavedMs, priced.EvidenceWeight
	candidate.firstContentCachedTokens, candidate.firstContentCacheWeight = priced.ForecastCache.Tokens, priced.ForecastCache.Weight
	candidate.firstContentRestoreMs, candidate.firstContentCacheExpiresAt = priced.ForecastCache.RestoreMS, priced.ForecastCache.ExpiresAt
}

// PriceForProviderLocked validates the endpoint at the pricing boundary. The
// caller holds the provider lock across validation and consuming the result.
// This is request-local service pricing, never physical admission.
func (hint CacheRoutingHint) PriceForProviderLocked(provider *Provider, model string, cost cachepolicy.ServiceCost, maxDiscountMs, maxCostFraction *float64) cachepolicy.ServiceCost {
	if !hint.CurrentForProviderLocked(provider, model) || (!hint.ExpiresAt.IsZero() && !time.Now().Before(hint.ExpiresAt)) {
		return cost
	}
	return cachepolicy.ApplyServiceCost(cachepolicy.ServiceHint{Tier: hint.Tier, PrefillTokensSaved: hint.PrefillTokensSaved,
		StageMs: hint.StageMs, EvidenceWeight: hint.EvidenceWeight, ExpiresAt: hint.ExpiresAt}, cost, maxDiscountMs, maxCostFraction)
}
