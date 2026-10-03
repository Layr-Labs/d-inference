package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
func (s *Owner) rejectRemoteMediaURLs(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, requiresVision, hasTools bool) (handled bool) {
	if !requiresVision {
		return false
	}
	badRef, ok := inreq.ValidateMediaParts(parsed)
	if ok {
		return false
	}
	s.writeRemoteMediaRejection(w, r, parsed, model, publicModel, hasTools,
		"image/video input must be an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); "+
			"remote http(s):// and file:// media URLs are not supported on this endpoint. Got: "+inreq.TruncateMediaRef(badRef))
	return true
}

// writeRemoteMediaRejection records + writes the standard pre-dispatch remote
// media 400 (identical telemetry shape for every remote-media rejection path:
// legacy data:-only, sealed-request, and unfetchable-shape — see
// gateRemoteMediaPreDispatch in media_resolve.go).
func (s *Owner) writeRemoteMediaRejection(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, hasTools bool, message string) {
	stream, _ := parsed["stream"].(bool)
	s.recordRejection(rejectionInfo{
		r:               r,
		stage:           "validation",
		reasonCode:      "bad_param",
		httpStatus:      http.StatusBadRequest,
		keyID:           access.KeyIDFromContext(r.Context()),
		consumerKeyHash: store.HashKey(access.ConsumerKeyFromContext(r.Context())),
		requestedModel:  publicModel,
		resolvedModel:   model,
		stream:          stream,
		requiresVision:  true,
		hasTools:        hasTools,
		params:          rejectionSamplingParams(parsed),
	})
	s.observation.Incr("inference.media_remote_url_rejected", []string{"model:" + model})
	httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", message, httpx.WithParam("messages")))
}
