package cachemetrics

import (
	"math"
	"strconv"

	metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TerminalTags(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid, usagePresent bool) []string {
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
		tier = metriclabels.LowCardinalityCacheTier(pr.CacheSelectionTier)
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

func TTFTSample(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid bool, actualTTFTMs float64) (float64, []string, bool) {
	if pr == nil || !usageValid || actualTTFTMs <= 0 || math.IsNaN(actualTTFTMs) || math.IsInf(actualTTFTMs, 0) {
		return 0, nil, false
	}
	if pr.CacheSelectionMode != "active" {
		return 0, nil, false
	}
	return actualTTFTMs, TerminalTags(pr, usage, true, true), true
}
