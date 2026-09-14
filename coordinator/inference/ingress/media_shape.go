package ingress

import (
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
func (s *Controller) rejectRemoteMediaURLs(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, requiresVision, hasTools bool) (handled bool) {
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
func (s *Controller) writeRemoteMediaRejection(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, hasTools bool, message string) {
	stream, _ := parsed["stream"].(bool)
	s.deps.Observer.Rejection(dispatch.Rejection{
		Request:         r,
		Stage:           "validation",
		ReasonCode:      "bad_param",
		HttpStatus:      http.StatusBadRequest,
		KeyID:           requestcontext.KeyID(r.Context()),
		ConsumerKeyHash: store.HashKey(requestcontext.AccountID(r.Context())),
		RequestedModel:  publicModel,
		ResolvedModel:   model,
		Stream:          stream,
		RequiresVision:  true,
		HasTools:        hasTools,
		Params:          rejectionSamplingParams(parsed),
	})
	s.deps.Metrics.Incr("inference.media_remote_url_rejected", []string{"model:" + model})
	httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", message, httpresponse.WithParam("messages")))
}
