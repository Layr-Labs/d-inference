package observation

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"math"
	"strconv"
)

func cacheSelectionTerminalTags(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid, usagePresent bool) []string {
	mode := "none"
	if pr != nil && pr.CacheSelectionMode == "active" {
		mode = pr.CacheSelectionMode
	}
	result := "unreported"
	lookupOutcome := "unreported"
	read := false
	if usagePresent && !usageValid {
		result = "invalid"
		lookupOutcome = "invalid"
	} else if usageValid {
		lookupOutcome = usage.CacheOutcome
		if usage.CacheOutcome == "hit" {
			result = "hit"
			read = true
		} else {
			result = "non_hit"
		}
	}
	tier := "none"
	selected := false
	if pr != nil {
		tier = LowCardinalityCacheTier(pr.CacheSelectionTier)
		selected = pr.CacheSelectionSelected
	}
	return []string{
		"mode:" + mode,
		"tier:" + tier,
		"selected:" + strconv.FormatBool(selected),
		"result:" + result,
		"lookup_outcome:" + lookupOutcome,
		"cache_read:" + strconv.FormatBool(read),
	}
}
func (s *Owner) EmitCacheSelectionTerminal(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid, usagePresent bool) bool {
	if pr == nil || !pr.CacheRoutingTelemetryEligible() {
		return false
	}
	if !pr.MarkCacheTerminalTelemetryEmitted() {
		return false
	}
	tags := cacheSelectionTerminalTags(pr, usage, usageValid, usagePresent)
	s.EmitModelCacheSelection(pr, tags, usage, usageValid)
	s.Incr("routing.cache_selection_terminal", tags)
	if pr.CacheSelectionDiscountMs > 0 {
		s.Histogram("routing.cache_selection_discount_ms", pr.CacheSelectionDiscountMs, tags)
		if pr.CacheSelectionMode == "active" && pr.CacheSelectionSelected {
			s.Incr("routing.cache_selection_precision", tags)
		}
	}
	s.EmitExactCacheEstimatedTTFTSaved(pr, tags)
	return true
}
func cacheSelectionTTFTSample(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid bool, actualTTFTMs float64) (float64, []string, bool) {
	if pr == nil || !usageValid || actualTTFTMs <= 0 || math.IsNaN(actualTTFTMs) || math.IsInf(actualTTFTMs, 0) {
		return 0, nil, false
	}
	if pr.CacheSelectionMode != "active" {
		return 0, nil, false
	}
	return actualTTFTMs, cacheSelectionTerminalTags(pr, usage, true, true), true
}
func (s *Owner) EmitCacheSelectionTTFT(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid bool, actualTTFTMs float64) {
	value, tags, ok := cacheSelectionTTFTSample(pr, usage, usageValid, actualTTFTMs)
	if !ok {
		return
	}
	s.cacheModelTiming("ttft", value, s.cacheModelSelectionLabels(pr.Model, tags)...)
	s.Histogram("routing.cache_selection_ttft_ms", value, tags)
}
