package ingress

import (
	"encoding/json"
)

// Media prompt-token costs. A vision encoder turns each image/video into a
// bounded number of soft tokens (Gemma 4 caps around a few hundred per image)
// regardless of the base64 byte length, so counting a `data:` URI as text
// inflates the estimate by orders of magnitude — distorting routing admission and
// over-reserving balance. Qwen's serving cap (8 frames, 512² pixels, temporal
// patch 2, spatial merge 2) is at most ~1024 video soft tokens, so 1500 remains
// conservative. These flat per-media costs keep both sane.
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

// jsonValueLen returns len(json.Marshal(v)), counting decoder-shaped values
// without allocating the encoding and marshaling anything else. A value the
// encoder rejects reports 0, exactly as the marshal-and-measure path did.
func jsonValueLen(v any) int {
	if n, ok := jsonEncodedLen(v); ok {
		return n
	}
	b, err := json.Marshal(v)
	if err != nil {
		return 0
	}
	return len(b)
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
		return textPromptTokens(x)
	default:
		n := jsonValueLen(v)
		if n == 0 {
			return 0
		}
		tokens := n / 4
		if tokens < 1 {
			tokens = 1
		}
		return tokens
	}
}

// textPromptTokens is the len/4 routing heuristic for one text string: empty
// text costs nothing, any other text at least one token.
func textPromptTokens(s string) int {
	if s == "" {
		return 0
	}
	if t := len(s) / 4; t > 0 {
		return t
	}
	return 1
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
		return jsonValueLen(v)
	}
}

// requestShape is everything the handlers derive from one walk of the
// messages / input / prompt tree: the media-aware routing token estimate, the
// byte-length billing bound, the count of image/video parts, and whether a
// non-empty tools array is declared.
//
// routingTokens and billingTokens are the field-level totals BEFORE the
// whole-body fallback: a request whose messages/input/prompt all estimate to
// zero is measured over the entire parsed body instead, and that fallback
// depends on fields the handler mutates after introspection (model,
// max_tokens, runtime defaults), so it is applied lazily by
// routingPromptTokens / billingPromptTokens at the call site.
type requestShape struct {
	routingTokens int
	billingTokens int
	mediaParts    int
	hasTools      bool
}

// introspectRequest composes the two passes below: the routing/media walk
// (type-level, never scans string contents) and the billing byte count (scans
// every string once). Handlers that need everything call this once; the
// single-value wrappers call only the pass they need.
func introspectRequest(parsed map[string]any) requestShape {
	routingTokens, mediaParts := routingShape(parsed)
	return requestShape{
		routingTokens: routingTokens,
		billingTokens: billingBytes(parsed),
		mediaParts:    mediaParts,
		hasTools:      requestHasTools(parsed),
	}
}

// routingShape walks messages[], input[] and prompt once for the media-aware
// routing estimate and the image/video part count.
func routingShape(parsed map[string]any) (routingTokens, mediaParts int) {
	if v, ok := parsed["messages"]; ok {
		tokens, media := messagesShape(v)
		routingTokens += tokens
		mediaParts += media
	}
	if v, ok := parsed["input"]; ok {
		tokens, media := inputShape(v)
		routingTokens += tokens
		mediaParts += media
	}
	if v, ok := parsed["prompt"]; ok {
		routingTokens += approximateTokenCount(v)
	}
	return routingTokens, mediaParts
}

// billingBytes is the byte-length reservation bound over the same fields.
// Billing MUST stay a guaranteed upper bound (len(bytes) >= tokens for any BPE
// tokenizer), so it counts full message bytes — including a base64 image's
// bytes and every non-content field (role, tool_calls, name). Switching to the
// media-aware flat count here would DROP those fields and under-reserve for
// tool-calling requests. Over-reservation on a large image is safe (it is
// refunded after inference); the routing/ITPM estimate is the media-aware one.
func billingBytes(parsed map[string]any) int {
	total := 0
	for _, field := range []string{"messages", "input", "prompt"} {
		if v, ok := parsed[field]; ok {
			total += approximateTokenCountUpperBound(v)
		}
	}
	return total
}

// routingPromptTokens is the routing/ITPM estimate, falling back to the whole
// body when no prompt-bearing field contributed.
func (s requestShape) routingPromptTokens(parsed map[string]any) int {
	if s.routingTokens == 0 {
		return approximateTokenCount(parsed)
	}
	return s.routingTokens
}

// billingPromptTokens is the reservation upper bound, falling back to the
// whole body when no prompt-bearing field contributed.
func (s requestShape) billingPromptTokens(parsed map[string]any) int {
	if s.billingTokens == 0 {
		return approximateTokenCountUpperBound(parsed)
	}
	return s.billingTokens
}

// requiresVision reports whether the request carries any image/video part.
func (s requestShape) requiresVision() bool { return s.mediaParts > 0 }

func estimatePromptTokens(parsed map[string]any) int {
	routingTokens, _ := routingShape(parsed)
	return requestShape{routingTokens: routingTokens}.routingPromptTokens(parsed)
}

// estimateBillingPromptTokens returns a guaranteed upper bound on prompt
// tokens for billing reservation. Uses byte-length (not len/4) so the
// pre-flight reservation always covers actual cost. This value must NOT
// be used for routing — see estimatePromptTokens for that.
func estimateBillingPromptTokens(parsed map[string]any) int {
	return requestShape{billingTokens: billingBytes(parsed)}.billingPromptTokens(parsed)
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

// stripProviderRoutingFields drops the retired consumer-side serial allowlist.
// Stable hardware identity is coordinator-private and must never be forwarded
// to a provider in the encrypted inference payload.
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
