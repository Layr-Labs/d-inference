package api

// request_introspection.go holds pure helpers for introspecting and lightly
// reshaping inbound inference request bodies before routing/dispatch:
// token and cost estimation (routing vs billing), media/tool detection,
// cache-affinity key derivation, and provider-serial allowlist parsing.
// These functions have no Server dependencies and are split out of consumer.go
// to keep the request-handling orchestrator thin.

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
)

// Media prompt-token costs. A vision encoder turns each image/video into a
// bounded number of soft tokens (Gemma 4 caps around a few hundred per image)
// regardless of the base64 byte length, so counting a `data:` URI as text
// inflates the estimate by orders of magnitude — distorting routing admission and
// over-reserving balance. These flat per-media costs keep both sane.
const (
	imagePromptTokenCost = 300
	videoPromptTokenCost = 1500
)

func intFromRequestValue(v any) (int, bool) {
	switch x := v.(type) {
	case int:
		return x, true
	case int32:
		return int(x), true
	case int64:
		return int(x), true
	case float64:
		return int(x), true
	case json.Number:
		n, err := x.Int64()
		if err != nil {
			return 0, false
		}
		return int(n), true
	default:
		return 0, false
	}
}

// approximateTokenCount returns a rough token estimate for routing and queue
// admission. The len/4 heuristic is a reasonable average for English text
// with GPT-style BPE tokenizers. This value feeds into the scheduler's
// capacity checks (pendingTokenBudget, freeMemoryAdmits) where a tighter
// estimate produces better routing decisions.
//
// For billing reservation (where underestimation causes provider shortfall),
// use approximateTokenCountUpperBound instead.
func approximateTokenCount(v any) int {
	if v == nil {
		return 0
	}
	switch x := v.(type) {
	case string:
		if x == "" {
			return 0
		}
		tokens := len(x) / 4
		if tokens < 1 {
			tokens = 1
		}
		return tokens
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return 0
		}
		tokens := len(b) / 4
		if tokens < 1 {
			tokens = 1
		}
		return tokens
	}
}

// approximateTokenCountUpperBound returns a guaranteed upper bound on the
// number of tokens a BPE tokenizer would produce for v. Every BPE vocabulary
// starts with one token per byte and can only merge, so len(text) >= tokens
// for any model family, any language, forever. This is used only for billing
// reservation to ensure the pre-flight debit always covers the actual cost.
//
// Using len(text) over-reserves by ~3-4x on average for English prose, but
// the difference is refunded immediately after inference completes, so
// consumers are never overcharged — they only need sufficient balance to
// cover the reservation hold.
func approximateTokenCountUpperBound(v any) int {
	if v == nil {
		return 0
	}
	switch x := v.(type) {
	case string:
		return len(x)
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return 0
		}
		return len(b)
	}
}

func estimatePromptTokens(parsed map[string]any) int {
	total := 0
	if v, ok := parsed["messages"]; ok {
		total += messagesPromptTokens(v)
	}
	if v, ok := parsed["input"]; ok {
		total += inputPromptTokens(v)
	}
	if v, ok := parsed["prompt"]; ok {
		total += approximateTokenCount(v)
	}
	if total == 0 {
		total = approximateTokenCount(parsed)
	}
	return total
}

// estimateBillingPromptTokens returns a guaranteed upper bound on prompt
// tokens for billing reservation. Uses byte-length (not len/4) so the
// pre-flight reservation always covers actual cost. This value must NOT
// be used for routing — see estimatePromptTokens for that.
func estimateBillingPromptTokens(parsed map[string]any) int {
	total := 0
	if v, ok := parsed["messages"]; ok {
		// Billing MUST stay a guaranteed upper bound (len(bytes) >= tokens for any
		// BPE tokenizer), so it keeps counting full message bytes — including a
		// base64 image's bytes and every non-content field (role, tool_calls,
		// name). Switching to the media-aware flat count here would DROP those
		// fields and under-reserve for tool-calling requests. Over-reservation on a
		// large image is safe (it is refunded after inference); the routing/ITPM
		// estimate (estimatePromptTokens) is the media-aware one.
		total += approximateTokenCountUpperBound(v)
	}
	if v, ok := parsed["input"]; ok {
		total += approximateTokenCountUpperBound(v)
	}
	if v, ok := parsed["prompt"]; ok {
		total += approximateTokenCountUpperBound(v)
	}
	if total == 0 {
		total = approximateTokenCountUpperBound(parsed)
	}
	return total
}

// isMediaPartType reports whether an OpenAI/OpenRouter content-part type denotes
// image or video input.
func isMediaPartType(t string) bool {
	switch t {
	// OpenAI chat (image_url/video_url), OpenAI Responses (input_image/input_video),
	// and Anthropic /v1/messages content blocks ({"type":"image"|"video","source":…}).
	case "image_url", "input_image", "image", "video_url", "input_video", "video":
		return true
	}
	return false
}

// messageContentTokens estimates ROUTING prompt tokens for one message's
// `content`, counting text parts as text (len/4) and each image/video part as a
// flat media cost (never the base64 length). Used only for the routing/ITPM
// estimate; billing uses approximateTokenCountUpperBound (a guaranteed upper
// bound that intentionally still counts the base64 bytes).
func messageContentTokens(content any) int {
	textTokens := func(s string) int {
		if s == "" {
			return 0
		}
		if t := len(s) / 4; t > 0 {
			return t
		}
		return 1
	}
	switch c := content.(type) {
	case string:
		return textTokens(c)
	case []any:
		total := 0
		for _, part := range c {
			pm, ok := part.(map[string]any)
			if !ok {
				continue
			}
			typ, _ := pm["type"].(string)
			switch {
			case typ == "text" || typ == "input_text":
				if s, ok := pm["text"].(string); ok {
					total += textTokens(s)
				}
			case typ == "image_url" || typ == "input_image" || typ == "image":
				total += imagePromptTokenCost
			case typ == "video_url" || typ == "input_video" || typ == "video":
				total += videoPromptTokenCost
			default:
				if b, err := json.Marshal(pm); err == nil {
					total += len(b) / 4
				}
			}
		}
		return total
	default:
		return approximateTokenCount(content)
	}
}

// messagesPromptTokens sums media-aware routing content tokens across a messages
// array. Falls back to the len/4 heuristic when messages isn't the standard
// array shape.
func messagesPromptTokens(messages any) int {
	arr, ok := messages.([]any)
	if !ok {
		return approximateTokenCount(messages)
	}
	total := 0
	for _, m := range arr {
		mm, ok := m.(map[string]any)
		if !ok {
			total += approximateTokenCount(m)
			continue
		}
		total += 4 // small per-message framing (role + delimiters)
		total += messageContentTokens(mm["content"])
	}
	return total
}

// inputPromptTokens estimates the Responses API `input` field. A string input
// is plain text (len/4). Structured input is an array of message-like items with
// `content` parts, so reuse the same media-aware content estimator as chat
// messages instead of counting JSON wrapper bytes.
func inputPromptTokens(input any) int {
	switch x := input.(type) {
	case string:
		return approximateTokenCount(x)
	case []any:
		total := 0
		for _, item := range x {
			switch m := item.(type) {
			case string:
				total += approximateTokenCount(m)
			case map[string]any:
				content, ok := m["content"]
				if !ok {
					total += approximateTokenCount(m)
					continue
				}
				total += 4 // role/type framing, matching messagesPromptTokens.
				total += messageContentTokens(content)
			default:
				total += approximateTokenCount(item)
			}
		}
		return total
	default:
		return approximateTokenCount(input)
	}
}

// contentPartsHaveMedia reports whether a `content` value (a content-part array)
// carries any image/video part.
func contentPartsHaveMedia(content any) bool {
	parts, ok := content.([]any)
	if !ok {
		return false
	}
	for _, part := range parts {
		pm, ok := part.(map[string]any)
		if !ok {
			continue
		}
		if typ, _ := pm["type"].(string); isMediaPartType(typ) {
			return true
		}
	}
	return false
}

// detectMediaRequirement reports whether the request carries image/video input.
// The coordinator sees plaintext at this point (sealedTransport decrypts before
// the handler), so this drives the vision routing gate and the fail-fast "no
// vision-capable provider" response. It scans both the Chat Completions
// `messages[].content` parts and the Responses API `input[].content` parts so a
// media request on either surface is gated (never silently routed text-blind).
func detectMediaRequirement(parsed map[string]any) bool {
	if messages, ok := parsed["messages"].([]any); ok {
		for _, m := range messages {
			if mm, ok := m.(map[string]any); ok && contentPartsHaveMedia(mm["content"]) {
				return true
			}
		}
	}
	// Responses API: `input` may be a string (no media) or an array of items,
	// each carrying `content` parts in the same image_url/input_image shape.
	if input, ok := parsed["input"].([]any); ok {
		for _, item := range input {
			if im, ok := item.(map[string]any); ok && contentPartsHaveMedia(im["content"]) {
				return true
			}
		}
	}
	return false
}

// requestHasTools reports whether the request carries a non-empty top-level
// "tools" array (Chat Completions and Responses API share the field name).
// Drives Traits.HasTools so tool-bearing requests only route to providers whose
// binaries survive tool-schema template rendering (version floor + per-model
// template_render_ok gate in the scheduler).
func requestHasTools(parsed map[string]any) bool {
	tools, ok := parsed["tools"].([]any)
	return ok && len(tools) > 0
}

func requestCacheAffinityKey(parsed map[string]any) string {
	raw, ok := parsed["prompt_cache_key"].(string)
	if !ok || raw == "" {
		return ""
	}
	const maxPromptCacheKeyBytes = 512
	if len(raw) > maxPromptCacheKeyBytes {
		return ""
	}
	sum := sha256.Sum256([]byte(raw))
	return fmt.Sprintf("%x", sum[:])
}

func estimateRequestedMaxTokens(parsed map[string]any) int {
	for _, key := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if n, ok := intFromRequestValue(parsed[key]); ok && n > 0 {
			if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
				return n * copies
			}
			return n
		}
	}
	if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
		return 256 * copies
	}
	return 256
}

func parseProviderSerialAllowlist(parsed map[string]any) ([]string, bool, error) {
	var rawValues []any
	provided := false
	for _, key := range []string{"provider_serial", "provider_serials"} {
		v, ok := parsed[key]
		if !ok {
			continue
		}
		provided = true
		switch x := v.(type) {
		case string:
			rawValues = append(rawValues, x)
		case []any:
			rawValues = append(rawValues, x...)
		default:
			return nil, true, fmt.Errorf("%s must be a string or array of strings", key)
		}
	}
	if !provided {
		return nil, false, nil
	}

	seen := make(map[string]struct{}, len(rawValues))
	ids := make([]string, 0, len(rawValues))
	for _, raw := range rawValues {
		id, ok := raw.(string)
		if !ok {
			return nil, true, fmt.Errorf("provider_serials must contain only strings")
		}
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return nil, true, fmt.Errorf("provider_serials must include at least one provider serial")
	}
	return ids, true, nil
}

func stripProviderRoutingFields(parsed map[string]any) bool {
	changed := false
	for _, key := range []string{"provider_serial", "provider_serials"} {
		if _, ok := parsed[key]; ok {
			delete(parsed, key)
			changed = true
		}
	}
	return changed
}
