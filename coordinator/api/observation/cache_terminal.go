package observation

import (
	cachemetrics "github.com/eigeninference/d-inference/coordinator/internal/observation/cachemetrics"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) EmitCacheSelectionTerminal(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid, usagePresent bool) bool {
	if pr == nil || !pr.CacheRoutingTelemetryEligible() {
		return false
	}
	if !pr.MarkCacheTerminalTelemetryEmitted() {
		return false
	}
	tags := cachemetrics.TerminalTags(pr, usage, usageValid, usagePresent)
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

func (s *Owner) EmitCacheSelectionTTFT(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid bool, actualTTFTMs float64) {
	value, tags, ok := cachemetrics.TTFTSample(pr, usage, usageValid, actualTTFTMs)
	if !ok {
		return
	}
	s.cacheModelTiming("ttft", value, s.cacheModelSelectionLabels(pr.Model, tags)...)
	s.Histogram("routing.cache_selection_ttft_ms", value, tags)
}
