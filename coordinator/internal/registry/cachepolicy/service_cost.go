package cachepolicy

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
)

// ServiceHint is the detached pricing evidence from a provider-aligned endpoint.
// The caller validates its generation, provider capability and expiry first.
type ServiceHint struct {
	Tier               string
	PrefillTokensSaved int
	StageMs            float64
	EvidenceWeight     float64
	ExpiresAt          time.Time
}

// ServiceCost carries request-local values, never mutable provider or tracker state.
type ServiceCost struct {
	Rates                performance.Rates
	PricedPromptTokens   int
	PrefillCostMs        float64
	CostMs               float64
	Breakdown            ServiceBreakdown
	Tier                 string
	EstimatedTTFTSavedMs float64
	EvidenceWeight       float64
	ForecastCache        forecast.CacheBenefit
}

// EvidenceWeight is a conservative age policy, not an empirically fitted hit
// probability. Capture it once per query so scan and reservation use the same
// evidence weight even as the wall clock advances between them.
func EvidenceWeight(updatedAt, expiresAt, now time.Time) float64 {
	lifetime := expiresAt.Sub(updatedAt)
	if lifetime <= 0 || !now.Before(expiresAt) {
		return 0
	}
	return min(1, float64(expiresAt.Sub(now))/float64(lifetime))
}

// serviceCost replaces the matched prompt's weighted prefill with its restore
// cost. A positive delta means staging costs more than recomputing; the provider
// still attempts that endpoint, so it cannot receive a cold score. Both signs
// use the base prefill's long-prompt multiplier, and stage is paid once in full.
// Load, decode, queue, pending, backlog and health remain intact. Physical
// admission never uses this adjustment.
func serviceCost(hint ServiceHint, candidate ServiceCost) (delta, ttftSaved float64) {
	if !capacityvalue.FinitePositive(candidate.Rates.ObservedPrefill) && !capacityvalue.FinitePositive(candidate.Rates.StaticPrefill) {
		return 0, 0
	}
	rate := candidate.Rates.Prefill()
	if !Tier(hint.Tier) || !capacityvalue.FinitePositive(rate) || candidate.PricedPromptTokens <= 0 ||
		!capacityvalue.FinitePositive(candidate.PrefillCostMs) || !capacityvalue.FinitePositive(candidate.CostMs) ||
		candidate.PrefillCostMs > candidate.CostMs || !capacityvalue.FinitePositive(hint.EvidenceWeight) ||
		hint.EvidenceWeight > 1 || hint.StageMs < 0 || math.IsNaN(hint.StageMs) || math.IsInf(hint.StageMs, 0) ||
		(hint.Tier != "memory" && hint.StageMs == 0) {
		return 0, 0
	}
	matched := min(hint.PrefillTokensSaved, candidate.PricedPromptTokens)
	if matched <= 0 {
		return 0, 0
	}
	coldPrefill := float64(candidate.PricedPromptTokens) / rate * 1000
	ttftSaved = float64(matched)/rate*1000*hint.EvidenceWeight - hint.StageMs
	if math.IsNaN(ttftSaved) || math.IsInf(ttftSaved, 0) || !capacityvalue.FinitePositive(coldPrefill) {
		return 0, 0
	}
	delta = -min(1, ttftSaved/coldPrefill) * candidate.PrefillCostMs
	if math.IsNaN(delta) || math.IsInf(delta, 0) || math.IsInf(candidate.CostMs+delta, 0) {
		return 0, 0
	}
	return delta, ttftSaved
}

// ApplyServiceCost prices authenticated evidence against the same detached
// snapshot as the base score. It returns a new value and never changes admission.
func ApplyServiceCost(hint ServiceHint, candidate ServiceCost, maxDiscountMs, maxCostFraction *float64) ServiceCost {
	delta, saved := serviceCost(hint, candidate)
	// Forecast work keeps the actual validated restore charge separate from
	// the legacy service-score discount caps. The estimator bounds reuse by
	// the exact planned prompt (when present), never by a maximum output limit.
	if Tier(hint.Tier) && capacityvalue.FinitePositive(hint.EvidenceWeight) && hint.EvidenceWeight <= 1 &&
		hint.PrefillTokensSaved > 0 && hint.StageMs >= 0 && !math.IsNaN(hint.StageMs) && !math.IsInf(hint.StageMs, 0) &&
		(hint.Tier == "memory" || hint.StageMs > 0) && !hint.ExpiresAt.IsZero() {
		candidate.ForecastCache = forecast.CacheBenefit{Tokens: float64(hint.PrefillTokensSaved), Weight: hint.EvidenceWeight,
			RestoreMS: hint.StageMs, ExpiresAt: hint.ExpiresAt}
	}
	if delta < 0 {
		// Safety caps limit benefits, never actual restore overhead.
		credit := -delta
		if maxDiscountMs != nil {
			credit = min(credit, *maxDiscountMs)
		}
		if maxCostFraction != nil {
			credit = min(credit, candidate.CostMs*(*maxCostFraction))
		}
		candidate.Breakdown.CacheDiscountMs = credit
		candidate.EvidenceWeight = hint.EvidenceWeight
		delta = -credit
	} else if delta > 0 {
		// Like the long-prompt blocking penalty, excess restore time belongs
		// to this request. This preserves the exported sum of cost terms.
		candidate.Breakdown.ThisReqMs += delta
	}
	if delta == 0 {
		return candidate
	}
	candidate.Tier = hint.Tier
	candidate.EstimatedTTFTSavedMs = saved
	candidate.CostMs += delta
	candidate.Breakdown.Total = candidate.CostMs
	return candidate
}
