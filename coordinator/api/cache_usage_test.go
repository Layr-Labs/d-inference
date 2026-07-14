package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestInvalidProviderCacheUsageIsCleared(t *testing.T) {
	usage := protocol.UsageInfo{
		PromptTokens: 10, CompletionTokens: 2,
		CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 20,
		PrefillTokensSaved: 19, CacheStageMs: 3,
	}
	if validCacheUsage(usage) {
		t.Fatal("impossible cached_tokens > prompt_tokens accepted")
	}
	clearCacheUsage(&usage)
	if usage.CacheOutcome != "" || usage.CacheTier != "" || usage.CachedTokens != 0 || usage.PrefillTokensSaved != 0 || usage.CacheStageMs != 0 {
		t.Fatalf("cache extension was not cleared: %+v", usage)
	}
	if usage.PromptTokens != 10 || usage.CompletionTokens != 2 {
		t.Fatalf("base completion usage was changed: %+v", usage)
	}
}

func TestOmittedOutcomeWithCacheFieldsRequiresSanitization(t *testing.T) {
	usage := protocol.UsageInfo{PromptTokens: 10, CachedTokens: 20, PrefillTokensSaved: 19}
	if !hasCacheUsage(usage) {
		t.Fatal("cache fields without outcome were not detected")
	}
	if validCacheUsage(usage) {
		t.Fatal("cache fields without outcome were accepted")
	}
	clearCacheUsage(&usage)
	if hasCacheUsage(usage) {
		t.Fatalf("invalid cache fields survived sanitization: %+v", usage)
	}
}

func TestCacheUsagePropagatesToOpenAIResponses(t *testing.T) {
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 2, CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 80, PrefillTokensSaved: 64}
	chat := buildNonStreamingResponse("request", "model", extractedMessage{Content: "ok"}, usage, 10, "", "")
	if chat.Usage.PromptTokensDetails == nil || chat.Usage.PromptTokensDetails.CachedTokens != 80 {
		t.Fatalf("chat cached usage = %+v", chat.Usage)
	}
	responses := buildResponsesResponse("request", "model", extractedMessage{Content: "ok"}, usage, 10, "", "")
	if responses.Usage.InputTokensDetail.CachedTokens != 80 {
		t.Fatalf("Responses cached usage = %+v", responses.Usage)
	}

	obj := map[string]any{"usage": map[string]any{
		"prompt_tokens":         100,
		"prompt_tokens_details": map[string]any{"cached_tokens": 999, "audio_tokens": 3},
	}, "choices": []any{}}
	line := finalizeUsageChunk(obj, usage, &registry.PendingRequest{Model: "model", PublicModel: "model"})
	var decoded map[string]any
	if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &decoded); err != nil {
		t.Fatal(err)
	}
	details := decoded["usage"].(map[string]any)["prompt_tokens_details"].(map[string]any)
	if details["cached_tokens"] != float64(80) || details["audio_tokens"] != float64(3) {
		t.Fatalf("stream cached usage = %+v", details)
	}

	raw := map[string]any{"usage": map[string]any{"prompt_tokens": 100, "prompt_tokens_details": map[string]any{"cached_tokens": 999, "audio_tokens": 3}}}
	injectCacheDetailIntoRawUsage(raw, usage)
	rawDetails := raw["usage"].(map[string]any)["prompt_tokens_details"].(map[string]any)
	if rawDetails["cached_tokens"] != 80 || rawDetails["audio_tokens"] != 3 {
		t.Fatalf("raw complete cached usage = %+v", rawDetails)
	}
}

func TestTerminalCacheUsageRemovesUntrustedRawDetails(t *testing.T) {
	zero := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 2}

	chat := map[string]any{"usage": map[string]any{
		"prompt_tokens_details": map[string]any{"cached_tokens": 999, "audio_tokens": 3},
	}}
	injectCacheDetailIntoRawUsage(chat, zero)
	chatDetails := chat["usage"].(map[string]any)["prompt_tokens_details"].(map[string]any)
	if _, exists := chatDetails["cached_tokens"]; exists || chatDetails["audio_tokens"] != 3 {
		t.Fatalf("raw chat details were not selectively sanitized: %+v", chatDetails)
	}

	streamObj := map[string]any{
		"choices": []any{},
		"usage":   map[string]any{"prompt_tokens_details": map[string]any{"cached_tokens": 999, "audio_tokens": 3}},
	}
	line := finalizeUsageChunk(streamObj, zero, &registry.PendingRequest{Model: "model"})
	var streamed map[string]any
	if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &streamed); err != nil {
		t.Fatal(err)
	}
	streamDetails := streamed["usage"].(map[string]any)["prompt_tokens_details"].(map[string]any)
	if _, exists := streamDetails["cached_tokens"]; exists || streamDetails["audio_tokens"] != float64(3) {
		t.Fatalf("held streaming details were not sanitized: %+v", streamDetails)
	}

	responses := map[string]any{"usage": map[string]any{
		"input_tokens_details": map[string]any{"cached_tokens": 999, "audio_tokens": 3},
	}}
	sanitizeCacheDetailIntoRawResponsesUsage(responses, zero)
	responseDetails := responses["usage"].(map[string]any)["input_tokens_details"].(map[string]any)
	if _, exists := responseDetails["cached_tokens"]; exists || responseDetails["audio_tokens"] != 3 {
		t.Fatalf("native Responses details were not sanitized: %+v", responseDetails)
	}

	valid := protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "hit", CacheTier: "memory", CachedTokens: 40, PrefillTokensSaved: 35}
	sanitizeCacheDetailIntoRawResponsesUsage(responses, valid)
	if got := responseDetails["cached_tokens"]; got != 40 {
		t.Fatalf("native Responses cached_tokens = %v, want authoritative 40", got)
	}
}

func TestCacheSelectionTerminalTagsAreLowCardinalityAndCorrelated(t *testing.T) {
	pr := &registry.PendingRequest{
		CacheRoute:         registry.CacheRoute{ExactKey: "secret-route-key"},
		CacheSelectionMode: "observe", CacheSelectionKind: "exact", CacheSelectionTier: "ssd",
		CacheSelectionDiscountMs: 42, CacheSelectionWouldChange: true,
	}
	tags := cacheSelectionTerminalTags(pr, protocol.UsageInfo{CacheOutcome: "miss_absent"}, true, true)
	joined := strings.Join(tags, ",")
	for _, want := range []string{"mode:observe", "kind:exact", "tier:ssd", "selected:false", "would_change:true", "result:non_hit"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("terminal selection tags %q missing %q", joined, want)
		}
	}
	if strings.Contains(joined, "secret-route-key") {
		t.Fatalf("terminal selection tags leaked a route key: %q", joined)
	}
	invalid := strings.Join(cacheSelectionTerminalTags(pr, protocol.UsageInfo{}, false, true), ",")
	if !strings.Contains(invalid, "result:invalid") {
		t.Fatalf("invalid terminal usage was not correlated: %q", invalid)
	}
}

func TestValidProviderCacheUsageShapes(t *testing.T) {
	if !validCacheUsage(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "hit", CacheTier: "memory", CachedTokens: 80, PrefillTokensSaved: 64, CacheStageMs: 1}) {
		t.Fatal("valid hit usage rejected")
	}
	if !validCacheUsage(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "miss_absent", CacheStageMs: 1}) {
		t.Fatal("valid miss usage rejected")
	}
	if validCacheUsage(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "miss_absent", CachedTokens: 1}) {
		t.Fatal("non-hit usage with cached tokens accepted")
	}
}
