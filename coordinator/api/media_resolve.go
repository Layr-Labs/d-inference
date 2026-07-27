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
	"context"
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
		// Resolver off means authoritative rollback to the data:-only contract:
		// one clean pre-dispatch 400 instead of a provider-side one.
		return s.rejectRemoteMediaURLs(w, r, parsed, model, publicModel, requiresVision, hasTools)
	}
	// Sender-sealed requests are never fetched: the sender opted into sealing
	// the payload to the coordinator, and a fetch would leak request-correlated
	// egress to the URL's origin. Reject with a clear next step.
	if mediafetch.HasRemoteMedia(parsed) && isSealedRequest(r) {
		s.writeRemoteMediaRejection(w, r, parsed, model, publicModel, hasTools,
			"sealed requests must send media as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); "+
				"remote image_url/video_url links are not fetched for sealed payloads — inline the media or disable request sealing")
		return true
	}
	// A remote reference in a shape the resolver does NOT fetch (Anthropic
	// source blocks, Responses input_image parts, file:// and other schemes)
	// keeps today's clean 400: dispatching it would either 400 across the fleet
	// or be silently dropped by the provider (an image-blind answer).
	if badRef, ok := firstUnfetchableRemoteRef(parsed); !ok {
		s.writeRemoteMediaRejection(w, r, parsed, model, publicModel, hasTools,
			"this media reference is not fetchable on this endpoint; send it as an OpenAI-style image_url/video_url http(s) link "+
				"or as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"). Got: "+truncateMediaRef(badRef))
		return true
	}
	return false
}

// firstUnfetchableRemoteRef returns ok=false with the first remote/non-inline
// media reference that the mediafetch resolver will NOT fetch based on that
// part's own shape and location (not URL equality with another part). OpenAI
// image_url/video_url http(s) parts are fetchable only under messages[];
// Anthropic/input_* shapes, non-http(s) schemes, and every Responses input[]
// media ref remain unsupported. Mirrors validateMediaParts' fail-open stance on
// unreadable shapes.
func firstUnfetchableRemoteRef(parsed map[string]any) (badRef string, ok bool) {
	check := func(content any, allowFetchableShape bool) (string, bool) {
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
			if !isInlineDataURI(ref) {
				if allowFetchableShape && mediafetch.IsFetchableRemotePart(pm) {
					continue
				}
				return ref, false
			}
		}
		return "", true
	}
	if msgs, isArr := parsed["messages"].([]any); isArr {
		for _, m := range msgs {
			if mm, isMap := m.(map[string]any); isMap {
				if ref, good := check(mm["content"], true); !good {
					return ref, false
				}
			}
		}
	}
	if input, isArr := parsed["input"].([]any); isArr {
		for _, it := range input {
			if im, isMap := it.(map[string]any); isMap {
				if ref, good := check(im["content"], false); !good {
					return ref, false
				}
			}
		}
	}
	return "", true
}

// mediaResolveMeta carries the request descriptors resolveRemoteMedia needs to
// record rejection telemetry with the same fidelity as the surrounding gates,
// plus the self-route context used to gate egress on serve-ability.
type mediaResolveMeta struct {
	model                 string
	publicModel           string
	stream                bool
	estimatedPromptTokens int
	requestedMaxTokens    int
	hasTools              bool
	requiresVision        bool
	// selfRoute (exclusive X-Darkbloom-Route: self) skips the balance
	// reservation, so the monetary cost gate that otherwise precedes a fetch is
	// absent. ownerAccountID is the caller's owned-provider set. resolveRemoteMedia
	// confirms the owner can actually serve the request BEFORE any fetch, so a
	// user with no linked/online/capable machine can't drive coordinator egress
	// and only then receive the self-route-unavailable error.
	//
	// traits carries the FULL routing traits, not just HasTools: a constrained
	// tool_choice raises RequiresToolConstraint, which providerEligibleForTraits
	// enforces, so reconstructing a partial trait set here would call an owned
	// provider serviceable and fetch before the real admission rejected it. The
	// traits are derived from the pre-inline body; runInferenceAdmission re-checks
	// with the post-inline set, which can only be stricter.
	selfRoute      bool
	ownerAccountID string
	traits         registry.RequestTraits
}

// resolveRemoteMedia is phase 2 (post-reservation): it fetches remote media
// URLs in the (already tool-schema normalized, JSON-parsed) request and inlines
// them. On success it returns the body to forward downstream — re-marshaled
// only when a URL was actually inlined — inlined=true when it was, and ok=true.
// On any failure it writes the terminal OpenAI-style error response and returns
// ok=false; the caller must refund the balance reservation and return
// immediately.
//
// parsed is mutated in place when media is inlined, so callers that also hold
// the parsed map (routing/alias fallback re-marshals) observe the inlined data:
// URIs consistently with the returned rawBody. inlined=true obliges the caller
// to refresh every view derived from the pre-inline body — the provider-bound
// body, the routing traits computed from it, and the balance reservation, which
// was taken while the media was still a ~100-byte URL.
func (s *Server) resolveRemoteMedia(w http.ResponseWriter, r *http.Request, rawBody []byte, parsed map[string]any, timing *registry.RequestTiming, meta mediaResolveMeta) (body []byte, inlined bool, ok bool) {
	if s.mediaResolver == nil || !s.mediaResolver.Enabled() {
		return rawBody, false, true
	}

	// Self-route skips the balance reservation, so nothing has yet gated egress
	// on serve-ability. Before fetching, confirm the owner has an online machine
	// that can serve this request; otherwise a user with no linked/offline/
	// incapable machine could drive up to the media-fetch caps of coordinator
	// egress and only then get the self-route error. Only runs when a fetch would
	// actually happen (remote media present); selfRouteUnavailable writes its own
	// terminal response. The later runInferenceAdmission re-checks (idempotent).
	if meta.selfRoute && mediafetch.HasRemoteMedia(parsed) {
		if s.selfRouteUnavailable(w, r, meta.ownerAccountID, meta.model,
			meta.traits, meta.requiresVision) {
			return nil, false, false
		}
	}

	start := time.Now()
	res, err := s.mediaResolver.Resolve(r.Context(), parsed)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			// The client is gone. The caller still refunds the monetary reservation,
			// but there is no response to write and no rejection/timeout telemetry to
			// emit: this was not an origin failure.
			return nil, false, false
		}
		var me *mediafetch.Error
		if !errors.As(err, &me) {
			me = &mediafetch.Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
				Public: "failed to fetch remote media", Internal: "unexpected resolver error"}
		}
		// Never log Internal here: media URLs often contain presigned credentials,
		// and wrapped network errors can reproduce the full URL. mediafetch.Error
		// keeps Internal non-sensitive as defense in depth, but the API log needs
		// only stable structured fields.
		s.logger.Warn("remote media rejected", "code", me.Code, "status", me.Status)
		s.mediaFetchRejected(w, r, parsed, meta, me.Status, me.Code, me.Public)
		return nil, false, false
	}
	if !res.Changed {
		return rawBody, false, true
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
		return nil, false, false
	}
	// The inlined body must still fit the sealed-frame budget. The dispatch-time
	// re-check would catch this too, but failing here names the actual cause
	// (media, not "your JSON") while the fetch is still the freshest context.
	if len(newBody) > maxInferenceBodyBytes {
		s.mediaFetchRejected(w, r, parsed, meta, http.StatusRequestEntityTooLarge, "media_too_large",
			"the request exceeds the size limit once remote media is inlined; use smaller media or fewer attachments")
		return nil, false, false
	}

	timing.MediaFetchedAt = time.Now()
	modelTag := []string{"model:" + meta.model}
	s.ddIncr("inference.media_fetch.ok", modelTag)
	s.ddCount("inference.media_fetch.items", int64(res.Count), modelTag)
	s.ddCount("inference.media_fetch.bytes", res.Bytes, modelTag)
	s.ddHistogram("inference.media_fetch.duration_ms", float64(time.Since(start).Milliseconds()), modelTag)
	return newBody, true, true
}

// mediaFetchRejected records + writes a terminal media-fetch failure with the
// standard rejection telemetry shape.
func (s *Server) mediaFetchRejected(w http.ResponseWriter, r *http.Request, parsed map[string]any, meta mediaResolveMeta, status int, code, message string) {
	reason := mediaRejectionReason(status)
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

// mediaRejectionReason maps a media-fetch failure's HTTP status onto the
// rejection-ledger reason_code, so the dashboards can tell a malformed consumer
// request apart from a blocked host, a slow origin and a broken upstream.
// Filing all of them as "bad_param" made every upstream fault look like a
// client bug. reason_code is a free-form TEXT column (store/postgres.go), so
// these values need no schema change.
func mediaRejectionReason(status int) string {
	switch status {
	case http.StatusForbidden:
		return "media_blocked"
	case http.StatusRequestTimeout:
		return "upstream_timeout"
	case http.StatusBadGateway, http.StatusGatewayTimeout:
		return "upstream_error"
	case http.StatusRequestEntityTooLarge:
		return "payload_too_large"
	default:
		return "bad_param"
	}
}
