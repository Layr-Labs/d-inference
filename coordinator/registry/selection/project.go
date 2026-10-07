package selection

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
)

// Project keeps first-content forecasts and health penalties independent of the
// legacy total service cost when ranking an eligible candidate. It reads the
// forecast and breakdown in place and retains neither; both must be non-nil.
func Project(providerID string, firstContent *forecast.Estimate, breakdown *cachepolicy.ServiceBreakdown, cacheSavedMs, cacheEvidenceWeight float64, affinityEligible bool) Candidate {
	return Candidate{
		ProviderID: providerID,
		ExpectedMs: firstContent.ExpectedMs, HealthMs: breakdown.HealthMs,
		CapacityRateMs: breakdown.CapacityRateMs, ServiceMs: firstContent.ServiceMs,
		CachedTokens: firstContent.CachedTokens, CacheSavedMs: cacheSavedMs,
		CacheEvidenceWeight: cacheEvidenceWeight, AffinityEligible: affinityEligible,
	}
}
