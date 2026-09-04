package api

// request_introspection.go holds helpers for introspecting and lightly
// reshaping inbound inference request bodies before routing/dispatch:
// token and cost estimation (routing vs billing), media/tool detection,
// remote media-URL rejection, and private routing-field stripping. Most are
// pure helpers with no Server
// state; the pre-dispatch media-URL rejection (rejectRemoteMediaURLs) hangs
// off *Server only to record rejection telemetry. Split out of consumer.go
// to keep the request-handling orchestrator thin.
//
// The estimates and media/tool detection share ONE walk of the message tree
// (introspectRequest → requestShape); estimatePromptTokens,
// estimateBillingPromptTokens, detectMediaRequirement, countMediaParts and
// requestHasTools are thin wrappers over it, so the handler can take every
// value from a single pass while callers that need just one keep their
// signature.
//
// Remote-media flow note: on the chat-completions surface the media resolver
// (media_resolve.go / coordinator/mediafetch) FETCHES remote image_url/video_url
// links and inlines them as data: URIs, so rejectRemoteMediaURLs only fires
// there when the resolver is disabled, the request is sender-sealed, or a
// remote reference sits in a shape the resolver does not fetch (see
// gateRemoteMediaPreDispatch). The generic (completions + Anthropic) surface
// keeps the unconditional rejection.

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
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
// routing estimate and the image/video part count, then adds the prompt-bearing
// fields that live OUTSIDE those arrays: the top-level tools[] schemas (Chat,
// Responses and Anthropic /v1/messages all carry them, and every chat template
// renders them into the prompt), the Anthropic top-level system prompt and the
// Responses instructions. Those three were never counted, so tool-schema-heavy
// agentic requests (1-8K tokens of definitions) ran a first-content deadline
// 1-8 s short on exactly the longest prefills, an under-counted ITPM charge, and
// could slip past the servability context gate into provider 5xx chains.
// billingBytes is unchanged (it is a byte upper bound, refunded after the fact).
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
	routingTokens += auxiliaryPromptTokens(parsed)
	return routingTokens, mediaParts
}

// auxiliaryPromptTokens is the len/4 estimate of the prompt-bearing top-level
// fields outside messages/input/prompt: tools[] (schema bytes / 4), the
// Anthropic system prompt (string or content blocks) and the Responses
// instructions string. Counted once, on the primary path only: when every
// prompt field is absent routingPromptTokens marshals the whole body, which
// already includes these fields, and a non-zero return here keeps that
// fallback from running, so the terms are never double-counted.
func auxiliaryPromptTokens(parsed map[string]any) int {
	total := 0
	if v, ok := parsed["tools"]; ok {
		total += jsonValueLen(v) / 4
	}
	if v, ok := parsed["system"]; ok {
		total += approximateTokenCount(v)
	}
	if v, ok := parsed["instructions"]; ok {
		total += approximateTokenCount(v)
	}
	return total
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

// contentShape estimates ROUTING prompt tokens for one message's `content`
// and counts its image/video parts in the same pass. Text parts count as text
// (len/4); each image/video part costs a flat media price (never the base64
// length) and counts as one media part; other part shapes count their JSON
// length. Non-object parts are skipped, exactly as the media detection always
// did. Used only for the routing/ITPM estimate; billing uses
// approximateTokenCountUpperBound (a guaranteed upper bound that intentionally
// still counts the base64 bytes).
func contentShape(content any) (tokens, mediaParts int) {
	switch c := content.(type) {
	case string:
		return textPromptTokens(c), 0
	case []any:
		for _, part := range c {
			pm, ok := part.(map[string]any)
			if !ok {
				continue
			}
			typ, _ := pm["type"].(string)
			switch {
			case typ == "text" || typ == "input_text":
				if s, ok := pm["text"].(string); ok {
					tokens += textPromptTokens(s)
				}
			case typ == "image_url" || typ == "input_image" || typ == "image":
				tokens += imagePromptTokenCost
				mediaParts++
			case typ == "video_url" || typ == "input_video" || typ == "video":
				tokens += videoPromptTokenCost
				mediaParts++
			default:
				tokens += jsonValueLen(pm) / 4
			}
		}
		return tokens, mediaParts
	default:
		return approximateTokenCount(content), 0
	}
}

// messagesShape sums media-aware routing content tokens and media parts across
// a messages array. Falls back to the len/4 heuristic (and no media) when
// messages isn't the standard array shape.
func messagesShape(messages any) (tokens, mediaParts int) {
	arr, ok := messages.([]any)
	if !ok {
		return approximateTokenCount(messages), 0
	}
	for _, m := range arr {
		mm, ok := m.(map[string]any)
		if !ok {
			tokens += approximateTokenCount(m)
			continue
		}
		t, media := contentShape(mm["content"])
		tokens += 4 + t // small per-message framing (role + delimiters)
		mediaParts += media
	}
	return tokens, mediaParts
}

// inputShape estimates the Responses API `input` field. A string input is
// plain text (len/4). Structured input is an array of message-like items with
// `content` parts, so reuse the same media-aware content estimator as chat
// messages instead of counting JSON wrapper bytes.
func inputShape(input any) (tokens, mediaParts int) {
	switch x := input.(type) {
	case string:
		return approximateTokenCount(x), 0
	case []any:
		for _, item := range x {
			switch m := item.(type) {
			case string:
				tokens += approximateTokenCount(m)
			case map[string]any:
				content, ok := m["content"]
				if !ok {
					tokens += approximateTokenCount(m)
					continue
				}
				t, media := contentShape(content)
				tokens += 4 + t // role/type framing, matching messagesShape.
				mediaParts += media
			default:
				tokens += approximateTokenCount(item)
			}
		}
		return tokens, mediaParts
	default:
		return approximateTokenCount(input), 0
	}
}

// detectMediaRequirement reports whether the request carries image/video input.
// The coordinator sees plaintext at this point (sealedTransport decrypts before
// the handler), so this drives the vision routing gate and the fail-fast "no
// vision-capable provider" response. It scans both the Chat Completions
// `messages[].content` parts and the Responses API `input[].content` parts so a
// media request on either surface is gated (never silently routed text-blind).
func detectMediaRequirement(parsed map[string]any) bool {
	return countMediaParts(parsed) > 0
}

// countMediaParts counts the image/video content parts across a chat
// (messages[]) or Responses API (input[]) body — the count-only vision shape
// term a capacity probe carries (protocol.CapacityProbeMessage
// VisionImageCount: counts, never bytes or content-derived dimensions).
// Same traversal as the routing estimate so the two can never disagree on
// what constitutes a media part.
func countMediaParts(parsed map[string]any) int {
	_, mediaParts := routingShape(parsed)
	return mediaParts
}

// isInlineDataURI reports whether a media reference is an inline base64 data: URI
// — the ONLY form the provider's E2E-encrypted VLM path accepts (see
// VLMRequestInference.MediaError.invalidURL, which 400s anything else).
func isInlineDataURI(s string) bool {
	return strings.HasPrefix(strings.TrimSpace(s), "data:")
}

// mediaPartURLString returns the URL/inline reference carried by a media content
// part and whether the part IS a media part. Covers OpenAI chat (image_url/
// video_url objects or bare strings), OpenAI Responses (input_image/input_video),
// and Anthropic source blocks ({type:"image"|"video", source:{type,…}}). A media
// part whose reference can't be read returns ("", true) so the caller fails OPEN.
func mediaPartURLString(pm map[string]any) (ref string, isMedia bool) {
	typ, _ := pm["type"].(string)
	if !isMediaPartType(typ) {
		return "", false
	}
	switch typ {
	case "image_url", "input_image", "video_url", "input_video":
		field := "image_url"
		if typ == "video_url" || typ == "input_video" {
			field = "video_url"
		}
		switch v := pm[field].(type) {
		case string:
			return v, true
		case map[string]any:
			if u, ok := v["url"].(string); ok {
				return u, true
			}
		}
		return "", true
	case "image", "video": // Anthropic source block
		if src, ok := pm["source"].(map[string]any); ok {
			switch st, _ := src["type"].(string); st {
			case "url":
				u, _ := src["url"].(string)
				return u, true // remote reference
			case "base64":
				// Inline raw base64 (not a data: URI). Treated as inline/OK in v1 —
				// the provider's Anthropic path accepts it; only remote refs are the
				// production storm. Marked inline so it is never rejected here.
				return "data:anthropic-inline-base64", true
			}
		}
		return "", true
	}
	return "", true
}

// validateMediaParts walks every media part in a chat (messages[]) or Responses
// (input[]) body and returns the first REMOTE / non-inline media reference. The
// provider VLM path accepts ONLY inline data: URIs, so a remote http(s)://,
// file://, or otherwise non-data: reference is the production gemma-vision 400
// source. Returns ok=false with the offending reference so the caller rejects it
// pre-dispatch (one clean 400) instead of dispatching and 400ing across the fleet.
// Unknown/unreadable part shapes fall through (fail-OPEN) — never wrongly 400 a
// body we don't model.
func validateMediaParts(parsed map[string]any) (badRef string, ok bool) {
	check := func(content any) (string, bool) {
		parts, ok := content.([]any)
		if !ok {
			return "", true
		}
		for _, p := range parts {
			pm, ok := p.(map[string]any)
			if !ok {
				continue
			}
			ref, isMedia := mediaPartURLString(pm)
			if !isMedia || ref == "" {
				continue
			}
			if !isInlineDataURI(ref) {
				return ref, false
			}
		}
		return "", true
	}
	if msgs, ok := parsed["messages"].([]any); ok {
		for _, m := range msgs {
			if mm, ok := m.(map[string]any); ok {
				if ref, good := check(mm["content"]); !good {
					return ref, false
				}
			}
		}
	}
	if input, ok := parsed["input"].([]any); ok {
		for _, it := range input {
			if im, ok := it.(map[string]any); ok {
				if ref, good := check(im["content"]); !good {
					return ref, false
				}
			}
		}
	}
	return "", true
}

// rejectRemoteMediaURLs fails a vision request fast (one terminal 400) when any
// media part carries a remote/non-inline URL, mirroring the provider's data:-only
// contract. Pre-dispatch — no provider is contacted. handled=true => caller returns.
//
// Unconditional by design, on every surface. The generic (completions +
// Anthropic) surface never fetches, so forwarding a remote URL there can only
// end in a provider-side 400 — the dispatch-then-provider-400 behavior this
// gate exists to eliminate. On the chat surface it is the authoritative
// data:-only fallback used when EIGENINFERENCE_MEDIA_FETCH_ENABLED=false.
// The retired DARKBLOOM_VISION_REJECT_REMOTE_URLS kill switch no longer gates
// it: disabling fetch must never re-enable forwarding.
func (s *Server) rejectRemoteMediaURLs(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, requiresVision, hasTools bool) (handled bool) {
	if !requiresVision {
		return false
	}
	badRef, ok := validateMediaParts(parsed)
	if ok {
		return false
	}
	s.writeRemoteMediaRejection(w, r, parsed, model, publicModel, hasTools,
		"image/video input must be an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); "+
			"remote http(s):// and file:// media URLs are not supported on this endpoint. Got: "+truncateMediaRef(badRef))
	return true
}

// truncateMediaRef bounds a consumer-supplied media reference for inclusion in
// an error message (URLs can be data: URIs megabytes long). The cut is a byte
// slice, so it can split a multibyte rune; the trailing partial rune is dropped
// rather than left for encoding/json to turn into U+FFFD.
func truncateMediaRef(ref string) string {
	if len(ref) > 200 {
		return strings.ToValidUTF8(ref[:200], "") + "…"
	}
	return ref
}

// writeRemoteMediaRejection records + writes the standard pre-dispatch remote
// media 400 (identical telemetry shape for every remote-media rejection path:
// legacy data:-only, sealed-request, and unfetchable-shape — see
// gateRemoteMediaPreDispatch in media_resolve.go).
func (s *Server) writeRemoteMediaRejection(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, hasTools bool, message string) {
	stream, _ := parsed["stream"].(bool)
	s.recordRejection(rejectionInfo{
		r:               r,
		stage:           "validation",
		reasonCode:      "bad_param",
		httpStatus:      http.StatusBadRequest,
		keyID:           keyIDFromContext(r.Context()),
		consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
		requestedModel:  publicModel,
		resolvedModel:   model,
		stream:          stream,
		requiresVision:  true,
		hasTools:        hasTools,
		params:          rejectionSamplingParams(parsed),
	})
	s.ddIncr("inference.media_remote_url_rejected", []string{"model:" + model})
	writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", message, withParam("messages")))
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
