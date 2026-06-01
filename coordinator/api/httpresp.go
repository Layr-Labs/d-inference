package api

// HTTP response helpers shared across the api package: the JSON writer and the
// OpenAI-compatible error-envelope builder.

import (
	"encoding/json"
	"net/http"
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// decodeJSONBody decodes the request body into dst. On failure it writes the
// standard 400 invalid_request_error and returns false, so callers can do:
//
//	if !decodeJSONBody(w, r, &req) {
//		return
//	}
//
// It is the single canonical home for the "decode or 400" boilerplate. Handlers
// that must tolerate an empty body (io.EOF) or combine the decode with field
// validation keep their bespoke decode and do not use this helper.
func decodeJSONBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return false
	}
	return true
}

// errorDetailOpt carries optional fields for OpenAI-compatible error responses.
type errorDetailOpt struct {
	param string // e.g. "model", "max_tokens"
	code  string // e.g. "model_not_found", "insufficient_quota"
}

// errorResponse builds a standard OpenAI-compatible error response body.
// By default, code is inferred from errType. Callers can override code or
// set param via withParam / withCode helpers.
func errorResponse(errType, message string, opts ...errorDetailOpt) map[string]any {
	detail := map[string]any{
		"type":    errType,
		"message": message,
		"code":    errType, // default: code mirrors type
	}
	for _, o := range opts {
		if o.param != "" {
			detail["param"] = o.param
		}
		if o.code != "" {
			detail["code"] = o.code
		}
	}
	return map[string]any{
		"error": detail,
	}
}

// withParam returns an option that sets the "param" field on an error response.
func withParam(p string) errorDetailOpt { return errorDetailOpt{param: p} }

// withCode returns an option that overrides the "code" field on an error response.
func withCode(c string) errorDetailOpt { return errorDetailOpt{code: c} }
