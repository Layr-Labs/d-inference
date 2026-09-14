// Package httprequest provides bounded request-body decoding for HTTP controllers.
package httprequest

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// ControlPlaneBodyLimit caps small unauthenticated control-plane JSON bodies.
const ControlPlaneBodyLimit = 64 << 10 // 64 KiB

// DecodeJSON JSON-decodes the request body under a hard size cap, writing
// a 413 (too large) or 400 (bad JSON) and returning false on failure. For small
// unauthenticated control-plane endpoints that must not buffer an unbounded body.
func DecodeJSON(w http.ResponseWriter, r *http.Request, maxBytes int64, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			httpresponse.WriteJSON(w, http.StatusRequestEntityTooLarge,
				httpresponse.ErrorBody("invalid_request_error", "request body too large"))
			return false
		}
		httpresponse.WriteJSON(w, http.StatusBadRequest,
			httpresponse.ErrorBody("invalid_request_error", "invalid JSON"))
		return false
	}
	return true
}
