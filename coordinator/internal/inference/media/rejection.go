package media

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// RejectURLs preserves the data-only contract on surfaces that never fetch.
func (s *Bridge) RejectURLs(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, requiresVision, hasTools bool) bool {
	if !requiresVision {
		return false
	}
	badRef, ok := inreq.ValidateMediaParts(parsed)
	if ok {
		return false
	}
	s.RejectRemote(w, r, parsed, model, publicModel, hasTools,
		"image/video input must be an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); "+
			"remote http(s):// and file:// media URLs are not supported on this endpoint. Got: "+inreq.TruncateMediaRef(badRef))
	return true
}

// RejectRemote emits the common pre-dispatch response after recording rejection.
func (s *Bridge) RejectRemote(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, hasTools bool, message string) {
	s.d.RecordRemote(r, parsed, model, publicModel, hasTools)
	s.d.Observation.Incr("inference.media_remote_url_rejected", []string{"model:" + model})
	httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", message, httpx.WithParam("messages")))
}
