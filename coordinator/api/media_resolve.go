package api

// media_resolve.go bridges the request prelude to the mediafetch package: it
// turns remote http(s) image_url/video_url links into inline base64 data: URIs on
// the coordinator (the trusted SSRF chokepoint) before the body is E2E-encrypted
// to a provider, so consumers can pass links instead of pre-encoding media. The
// provider keeps seeing only data: URIs — its hardened non-data: guard is
// unchanged (defense in depth).
//
// Sender-sealed (zero-knowledge) requests are never fetched: fetching a URL would
// force the coordinator to act on the sealed payload and leak which third party
// the consumer addressed. Such requests are rejected with a clear error telling
// the sender to inline the media as a data: URI instead.

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/mediafetch"
)

// resolveRemoteMedia resolves remote media URLs in the (already tool-schema
// normalized, JSON-parsed) request. On success it returns the request body to
// forward downstream — re-marshaled only when a URL was actually inlined — and
// ok=true. On any failure it writes the terminal OpenAI-style error response and
// returns ok=false; the caller must return immediately.
//
// parsed is mutated in place when media is inlined, so callers that also hold the
// parsed map (routing/billing) observe the inlined data: URIs consistently with
// the returned rawBody.
func (s *Server) resolveRemoteMedia(w http.ResponseWriter, r *http.Request, rawBody []byte, parsed map[string]any) ([]byte, bool) {
	if s.mediaResolver == nil {
		return rawBody, true
	}

	// Zero-knowledge requests: refuse remote URLs (never unseal-to-fetch).
	if isSealedRequest(r) {
		if mediafetch.HasRemoteMedia(parsed) {
			s.ddIncr("media_fetch.error", []string{"code:sealed_remote_media"})
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				"sender-sealed requests must send media as an inline base64 data: URI; remote image_url/video_url links are not supported on encrypted requests",
				withParam("messages")))
			return nil, false
		}
		return rawBody, true
	}

	res, err := s.mediaResolver.Resolve(r.Context(), parsed)
	if err != nil {
		var me *mediafetch.Error
		if errors.As(err, &me) {
			// Internal carries the URL/host/cause for operators; the consumer
			// gets only the generic Public message (no internal host leakage).
			s.logger.Warn("remote media rejected", "code", me.Code, "detail", me.Internal)
			s.ddIncr("media_fetch.error", []string{"code:" + me.Code})
			writeJSON(w, me.Status, errorResponse(me.Code, me.Public, withParam("messages")))
		} else {
			s.logger.Warn("remote media fetch failed", "error", err)
			s.ddIncr("media_fetch.error", []string{"code:unknown"})
			writeJSON(w, http.StatusBadGateway, errorResponse("media_fetch_failed",
				"failed to fetch remote media", withParam("messages")))
		}
		return nil, false
	}

	if !res.Changed {
		return rawBody, true
	}

	// A URL was inlined — re-marshal so the forwarded body reflects the data: URI.
	// Use marshalForwardBody (HTML-escaping disabled) to match the body the
	// handlers actually seal, so the routing/billing/size view is consistent with
	// the encrypted payload rather than an HTML-escaped (inflated) variant.
	newBody, mErr := marshalForwardBody(parsed)
	if mErr != nil {
		s.logger.Error("re-marshal after media inline failed", "error", mErr)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error",
			"failed to process request media"))
		return nil, false
	}
	s.ddIncr("media_fetch.success", nil)
	s.ddCount("media_fetch.items", int64(res.Count), nil)
	s.ddCount("media_fetch.bytes", res.Bytes, nil)
	return newBody, true
}
