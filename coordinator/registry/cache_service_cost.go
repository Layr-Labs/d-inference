package registry

import (
	"math"
	"time"
)

// cacheEvidenceWeight is a conservative age policy, not an empirically fitted
// hit probability. Capture it once per query so scan and reservation use the
// same evidence weight even as the wall clock advances between them.
func cacheEvidenceWeight(holder cacheHolder, now time.Time) float64 {
	lifetime := holder.ExpiresAt.Sub(holder.UpdatedAt)
	if lifetime <= 0 || !now.Before(holder.ExpiresAt) {
		return 0
	}
	return min(1, float64(holder.ExpiresAt.Sub(now))/float64(lifetime))
}

// cacheServiceCost replaces the matched prompt's weighted prefill with its
// restore cost. A positive delta means staging costs more than recomputing;
// the provider still attempts that endpoint, so it cannot receive a cold score.
// Both signs use the base prefill's long-prompt multiplier, and stage is paid
// once in full. Load, decode, queue, pending, backlog and health remain intact.
// Physical admission never uses this adjustment.
func cacheServiceCost(hint cacheRoutingHint, candidate *routingCandidate) (delta, ttftSaved float64) {
	rate := resolvePrefillTPS(&candidate.snapshot)
	if !validCacheReceiptTier(hint.Tier) || !finitePositive(rate) || candidate.pricedPromptTokens <= 0 ||
		!finitePositive(candidate.prefillCostMs) || !finitePositive(candidate.costMs) ||
		candidate.prefillCostMs > candidate.costMs || !finitePositive(hint.EvidenceWeight) ||
		hint.EvidenceWeight > 1 || hint.StageMs < 0 || math.IsNaN(hint.StageMs) || math.IsInf(hint.StageMs, 0) ||
		(hint.Tier != "memory" && hint.StageMs == 0) {
		return 0, 0
	}
	matched := min(hint.PrefillTokensSaved, candidate.pricedPromptTokens)
	if matched <= 0 {
		return 0, 0
	}
	coldPrefill := float64(candidate.pricedPromptTokens) / rate * 1000
	ttftSaved = float64(matched)/rate*1000*hint.EvidenceWeight - hint.StageMs
	if math.IsNaN(ttftSaved) || math.IsInf(ttftSaved, 0) || !finitePositive(coldPrefill) {
		return 0, 0
	}
	delta = -min(1, ttftSaved/coldPrefill) * candidate.prefillCostMs
	if math.IsNaN(delta) || math.IsInf(delta, 0) || math.IsInf(candidate.costMs+delta, 0) {
		return 0, 0
	}
	return delta, ttftSaved
}

func finitePositive(value float64) bool {
	return value > 0 && !math.IsNaN(value) && !math.IsInf(value, 0)
}

// applyCacheHintLocked prices the provider-aligned endpoint with the same
// candidate snapshot as the base score. Caller holds provider.mu and r.mu.
func (r *Registry) applyCacheHintLocked(hint cacheRoutingHint, model string, candidate *routingCandidate) {
	if !hint.currentForProviderLocked(candidate.provider, model) {
		return
	}
	delta, saved := cacheServiceCost(hint, candidate)
	if delta < 0 {
		// Safety caps limit benefits, never actual restore overhead.
		credit := -delta
		if r.cacheRoutingMaxDiscountMs != nil {
			credit = min(credit, *r.cacheRoutingMaxDiscountMs)
		}
		if r.cacheRoutingMaxCostFraction != nil {
			credit = min(credit, candidate.costMs*(*r.cacheRoutingMaxCostFraction))
		}
		candidate.breakdown.CacheDiscountMs = credit
		delta = -credit
	} else if delta > 0 {
		// Like the long-prompt blocking penalty, excess restore time belongs
		// to this request. This preserves the exported sum of cost terms.
		candidate.breakdown.ThisReqMs += delta
	}
	if delta == 0 {
		return
	}
	candidate.cacheTier = hint.Tier
	candidate.cacheEstimatedTTFTSavedMs = saved
	candidate.costMs += delta
	candidate.breakdown.Total = candidate.costMs
}
