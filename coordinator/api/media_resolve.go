package api

// media_resolve.go bridges the chat-completions handler to the mediafetch
// package: it turns remote http(s) image_url/video_url links into inline base64
// data: URIs on the coordinator (the trusted SSRF chokepoint) before the body is
// E2E-encrypted to a provider, so consumers can pass links the way they do with
// OpenAI instead of pre-encoding media. The provider keeps seeing only data:
// URIs — its hardened non-data: guard is unchanged (defense in depth).
//
// Two-phase flow (both phases chat-completions-only; the generic completions +
// Anthropic surface keeps the unconditional pre-dispatch rejection):
//
//  1. gateRemoteMediaPreDispatch — BEFORE token admission/billing. Fails fast
//     the cases that must never fetch: sender-sealed requests (fetching would
//     generate origin-observable egress correlated with a payload the sender
//     chose to seal), remote refs in shapes the resolver does not fetch
//     (Anthropic source blocks, input_image — which would otherwise dispatch
//     and be silently dropped by the provider, answering image-blind), and the
//     resolver-disabled fallback (legacy one-clean-400).
//  2. resolveRemoteMedia — AFTER token admission and the balance reservation,
//     so network I/O is gated behind the cost gates (an authenticated but
//     unfunded/over-quota request can never drive coordinator-side fetches).
//     The caller refunds the reservation on failure.

import (
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// gateRemoteMediaPreDispatch is phase 1 (pre-billing) of remote media handling
// on the chat surface. handled=true => a terminal response was written and the
// caller must return.
func (s *Server) gateRemoteMediaPreDispatch(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, requiresVision, hasTools bool) (handled bool) {
	if !requiresVision {
		return false
	}
	if s.mediaResolver == nil || !s.mediaResolver.Enabled() {
		// Resolver off → the legacy pre-dispatch rejection (which respects its
		// own DARKBLOOM_VISION_REJECT_REMOTE_URLS kill switch).
		return s.rejectRemoteMediaURLs(w, r, parsed, model, publicModel, requiresVision, hasTools)
	}
	fetchable := mediafetch.RemoteMediaURLs(parsed)
	// Sender-sealed requests are never fetched: the sender opted into sealing
	// the payload to the coordinator, and a fetch would leak request-correlated
	// egress to the URL's origin. Reject with a clear next step.
	if len(fetchable) > 0 && isSealedRequest(r) {
		s.writeRemoteMediaRejection(w, r, parsed, model, publicModel, hasTools,
			"sealed requests must send media as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); "+
				"remote image_url/video_url links are not fetched for sealed payloads — inline the media or disable request sealing")
		return true
	}
	// A remote reference in a shape the resolver does NOT fetch (Anthropic
	// source blocks, Responses input_image parts, file:// and other schemes)
	// keeps today's clean 400: dispatching it would either 400 across the fleet
	// or be silently dropped by the provider (an image-blind answer).
	if badRef, ok := firstUnfetchableRemoteRef(parsed, fetchable); !ok {
		s.writeRemoteMediaRejection(w, r, parsed, model, publicModel, hasTools,
			"this media reference is not fetchable on this endpoint; send it as an OpenAI-style image_url/video_url http(s) link "+
				"or as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"). Got: "+truncateMediaRef(badRef))
		return true
	}
	return false
}

// firstUnfetchableRemoteRef returns ok=false with the first remote/non-inline
// media reference that the mediafetch resolver will NOT fetch — i.e. a remote
// ref whose URL is not in the resolver's fetchable set (non-OpenAI part shapes,
// non-http(s) schemes) — across both the messages[] and Responses input[]
// surfaces. Mirrors validateMediaParts' fail-open stance on unreadable shapes.
func firstUnfetchableRemoteRef(parsed map[string]any, fetchable map[string]bool) (badRef string, ok bool) {
	check := func(content any) (string, bool) {
		parts, isArr := content.([]any)
		if !isArr {
			return "", true
		}
		for _, p := range parts {
			pm, isMap := p.(map[string]any)
			if !isMap {
				continue
			}
			ref, isMedia := mediaPartURLString(pm)
			if !isMedia || ref == "" {
				continue
			}
			if !isInlineDataURI(ref) && !fetchable[ref] {
				return ref, false
			}
		}
		return "", true
	}
	if msgs, isArr := parsed["messages"].([]any); isArr {
		for _, m := range msgs {
			if mm, isMap := m.(map[string]any); isMap {
				if ref, good := check(mm["content"]); !good {
					return ref, false
				}
			}
		}
	}
	if input, isArr := parsed["input"].([]any); isArr {
		for _, it := range input {
			if im, isMap := it.(map[string]any); isMap {
				if ref, good := check(im["content"]); !good {
					return ref, false
				}
			}
		}
	}
	return "", true
}

// mediaResolveMeta carries the request descriptors resolveRemoteMedia needs to
// record rejection telemetry with the same fidelity as the surrounding gates.
type mediaResolveMeta struct {
	model                 string
	publicModel           string
	stream                bool
	estimatedPromptTokens int
	requestedMaxTokens    int
	hasTools              bool
}

// resolveRemoteMedia is phase 2 (post-reservation): it fetches remote media
// URLs in the (already tool-schema normalized, JSON-parsed) request and inlines
// them. On success it returns the body to forward downstream — re-marshaled
// only when a URL was actually inlined — and ok=true. On any failure it writes
// the terminal OpenAI-style error response and returns ok=false; the caller
// must refund the balance reservation and return immediately.
//
// parsed is mutated in place when media is inlined, so callers that also hold
// the parsed map (routing/alias fallback re-marshals) observe the inlined data:
// URIs consistently with the returned rawBody.
func (s *Server) resolveRemoteMedia(w http.ResponseWriter, r *http.Request, rawBody []byte, parsed map[string]any, timing *registry.RequestTiming, meta mediaResolveMeta) ([]byte, bool) {
	if s.mediaResolver == nil || !s.mediaResolver.Enabled() {
		return rawBody, true
	}

	start := time.Now()
	res, err := s.mediaResolver.Resolve(r.Context(), parsed)
	if err != nil {
		var me *mediafetch.Error
		if !errors.As(err, &me) {
			me = &mediafetch.Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
				Public: "failed to fetch remote media", Internal: err.Error()}
		}
		// Internal carries the URL/host/cause for operators; the consumer gets
		// only the generic Public message (no internal host/DNS leakage).
		s.logger.Warn("remote media rejected", "code", me.Code, "status", me.Status, "detail", me.Internal)
		s.mediaFetchRejected(w, r, parsed, meta, me.Status, me.Code, me.Public)
		return nil, false
	}
	if !res.Changed {
		return rawBody, true
	}

	// A URL was inlined — re-marshal so the forwarded body reflects the data:
	// URI. marshalForwardBody (HTML-escaping disabled) matches the body the
	// handler actually seals, so the routing/size view is consistent with the
	// encrypted payload rather than an HTML-escaped (inflated) variant.
	newBody, mErr := marshalForwardBody(parsed)
	if mErr != nil {
		s.logger.Error("re-marshal after media inline failed", "error", mErr)
		s.ddIncr("inference.media_fetch.rejected", []string{"code:remarshal_failed", "model:" + meta.model})
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error",
			"failed to process request media"))
		return nil, false
	}
	// The inlined body must still fit the sealed-frame budget. The dispatch-time
	// re-check would catch this too, but failing here names the actual cause
	// (media, not "your JSON") while the fetch is still the freshest context.
	if len(newBody) > maxInferenceBodyBytes {
		s.mediaFetchRejected(w, r, parsed, meta, http.StatusRequestEntityTooLarge, "media_too_large",
			"the request exceeds the size limit once remote media is inlined; use smaller media or fewer attachments")
		return nil, false
	}

	timing.MediaFetchedAt = time.Now()
	modelTag := []string{"model:" + meta.model}
	s.ddIncr("inference.media_fetch.ok", modelTag)
	s.ddCount("inference.media_fetch.items", int64(res.Count), modelTag)
	s.ddCount("inference.media_fetch.bytes", res.Bytes, modelTag)
	s.ddHistogram("inference.media_fetch.duration_ms", float64(time.Since(start).Milliseconds()), modelTag)
	return newBody, true
}

// mediaFetchRejected records + writes a terminal media-fetch failure with the
// standard rejection telemetry shape.
func (s *Server) mediaFetchRejected(w http.ResponseWriter, r *http.Request, parsed map[string]any, meta mediaResolveMeta, status int, code, message string) {
	reason := "bad_param"
	if status == http.StatusRequestEntityTooLarge {
		reason = "payload_too_large"
	}
	s.recordRejection(rejectionInfo{
		r:                     r,
		stage:                 "validation",
		reasonCode:            reason,
		httpStatus:            status,
		keyID:                 keyIDFromContext(r.Context()),
		consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
		requestedModel:        meta.publicModel,
		resolvedModel:         meta.model,
		stream:                meta.stream,
		estimatedPromptTokens: meta.estimatedPromptTokens,
		requestedMaxTokens:    meta.requestedMaxTokens,
		requiresVision:        true,
		hasTools:              meta.hasTools,
		params:                rejectionSamplingParams(parsed),
	})
	s.ddIncr("inference.media_fetch.rejected", []string{"code:" + code, "model:" + meta.model})
	writeJSON(w, status, errorResponse(code, message, withParam("messages")))
}
