package api

import (
	"encoding/json"
	"math"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func lowCardinalityCacheTier(tier string) string {
	if tier == "memory" || tier == "ssd" {
		return tier
	}
	return "none"
}

func validCacheUsage(usage protocol.UsageInfo) bool {
	switch usage.CacheOutcome {
	case "":
		return false
	case "hit", "miss_absent", "miss_corrupt", "skipped_capacity", "skipped_cost", "skipped_policy":
	default:
		return false
	}
	if usage.CacheTier != "" && usage.CacheTier != "memory" && usage.CacheTier != "ssd" {
		return false
	}
	const maxCacheUsageTokens = 1_000_000
	if usage.CachedTokens < 0 || usage.CachedTokens > maxCacheUsageTokens || usage.CachedTokens > usage.PromptTokens ||
		usage.PrefillTokensSaved < 0 || usage.PrefillTokensSaved > usage.CachedTokens ||
		usage.CacheStageMs < 0 || usage.CacheStageMs > 10*60*1000 || math.IsNaN(usage.CacheStageMs) || math.IsInf(usage.CacheStageMs, 0) {
		return false
	}
	if usage.CacheOutcome == "hit" {
		return usage.CacheTier != "" && usage.CachedTokens > 0 && usage.PrefillTokensSaved > 0
	}
	return usage.CachedTokens == 0 && usage.PrefillTokensSaved == 0
}

func clearCacheUsage(usage *protocol.UsageInfo) {
	if usage == nil {
		return
	}
	usage.CacheOutcome = ""
	usage.CacheTier = ""
	usage.CachedTokens = 0
	usage.PrefillTokensSaved = 0
	usage.CacheStageMs = 0
}

func hasCacheUsage(usage protocol.UsageInfo) bool {
	return usage.CacheOutcome != "" || usage.CacheTier != "" || usage.CachedTokens != 0 ||
		usage.PrefillTokensSaved != 0 || usage.CacheStageMs != 0
}

func injectCacheDetailIntoRawUsage(obj map[string]any, usage protocol.UsageInfo) {
	setCachedTokenDetail(obj, "prompt_tokens_details", usage.CachedTokens)
}

func sanitizeCacheDetailIntoRawResponsesUsage(obj map[string]any, usage protocol.UsageInfo) {
	setCachedTokenDetail(obj, "input_tokens_details", usage.CachedTokens)
}

func setCachedTokenDetail(obj map[string]any, detailField string, cachedTokens int) {
	usageObj, ok := obj["usage"].(map[string]any)
	if !ok {
		return
	}
	details, detailsOK := usageObj[detailField].(map[string]any)
	if details == nil {
		if cachedTokens <= 0 {
			// A malformed/non-object provider detail cannot be selectively
			// sanitized, so remove it rather than forwarding untrusted cache data.
			if !detailsOK {
				delete(usageObj, detailField)
			}
			return
		}
		details = map[string]any{}
	}
	if cachedTokens > 0 {
		details["cached_tokens"] = cachedTokens
	} else {
		delete(details, "cached_tokens")
	}
	if len(details) == 0 {
		delete(usageObj, detailField)
	} else {
		usageObj[detailField] = details
	}
}

func removeCachedTokenDetail(usageObj map[string]any, detailField string) bool {
	details, ok := usageObj[detailField].(map[string]any)
	if !ok || details == nil {
		return false
	}
	if _, exists := details["cached_tokens"]; !exists {
		return false
	}
	delete(details, "cached_tokens")
	if len(details) == 0 {
		delete(usageObj, detailField)
	} else {
		usageObj[detailField] = details
	}
	return true
}

func sanitizeStreamCacheDetailsJSON(raw string) (string, bool) {
	var obj map[string]any
	if json.Unmarshal([]byte(raw), &obj) != nil {
		return raw, false
	}
	changed := false
	if usageObj, ok := obj["usage"].(map[string]any); ok {
		changed = removeCachedTokenDetail(usageObj, "prompt_tokens_details") || changed
		changed = removeCachedTokenDetail(usageObj, "input_tokens_details") || changed
	}
	if response, ok := obj["response"].(map[string]any); ok {
		if usageObj, ok := response["usage"].(map[string]any); ok {
			changed = removeCachedTokenDetail(usageObj, "prompt_tokens_details") || changed
			changed = removeCachedTokenDetail(usageObj, "input_tokens_details") || changed
		}
	}
	if !changed {
		return raw, false
	}
	b, err := marshalForwardBody(obj)
	if err != nil {
		return raw, false
	}
	return string(b), true
}

func sseDataValue(line string) (string, bool) {
	colon := strings.IndexByte(line, ':')
	field, value := line, ""
	if colon >= 0 {
		field, value = line[:colon], line[colon+1:]
		if strings.HasPrefix(value, " ") {
			value = value[1:]
		}
	}
	return value, field == "data"
}

func sanitizeStreamCacheEventGroup(group string) (string, bool) {
	lines := strings.Split(group, "\n")
	data := make([]string, 0, len(lines))
	firstData := -1
	for i, line := range lines {
		if value, ok := sseDataValue(line); ok {
			if firstData < 0 {
				firstData = i
			}
			data = append(data, value)
		}
	}
	if firstData < 0 {
		if len(lines) == 1 {
			if sanitized, ok := sanitizeStreamCacheDetailsJSON(strings.TrimSpace(group)); ok {
				return sanitized, true
			}
		}
		return group, false
	}
	sanitized, changed := sanitizeStreamCacheDetailsJSON(strings.Join(data, "\n"))
	if !changed {
		return group, false
	}
	out := make([]string, 0, len(lines)-len(data)+1)
	for i, line := range lines {
		if _, ok := sseDataValue(line); ok {
			if i == firstData {
				out = append(out, "data: "+sanitized)
			}
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n"), true
}

// sanitizeStreamCacheDetails removes provider-supplied cached_tokens from any
// streamed frame before it can reach the consumer. SSE data fields are joined
// per the specification across each blank-line-delimited event, then a changed
// payload is emitted as one safe data line while event/id/comments are retained.
// Terminal usage is validated independently and re-added only to the held usage
// frame at stream completion.
func sanitizeStreamCacheDetails(chunk string) string {
	// A normal field takes the literal fast path. A disguised equivalent must use
	// a JSON Unicode escape (for example cached\u005ftokens); no other valid JSON
	// escape can encode an ASCII letter or underscore. Parse those frames too,
	// while leaving the overwhelmingly common escape-free content frame untouched.
	if !strings.Contains(chunk, `"cached_tokens"`) && !strings.Contains(chunk, `\u`) {
		return chunk
	}
	normalized := strings.ReplaceAll(strings.ReplaceAll(chunk, "\r\n", "\n"), "\r", "\n")
	groups := strings.Split(normalized, "\n\n")
	changed := false
	for i, group := range groups {
		if sanitized, ok := sanitizeStreamCacheEventGroup(group); ok {
			groups[i] = sanitized
			changed = true
		}
	}
	if changed {
		return strings.Join(groups, "\n\n")
	}
	return chunk
}
