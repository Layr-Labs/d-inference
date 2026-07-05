package api

// Small HTTP response helpers shared across the consumer/provider/billing
// handlers: JSON writing and the OpenAI-compatible error envelope.

import (
	"encoding/json"
	"net/http"
)

// writeJSON serializes v as JSON and writes it to the response with the
// given HTTP status code. Sets Content-Type to application/json.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
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
