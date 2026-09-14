// Package httpresponse writes the shared JSON and OpenAI-compatible error envelopes.
package httpresponse

// Small HTTP response helpers shared across the consumer/provider/billing
// handlers: JSON writing and the OpenAI-compatible error envelope.

import (
	"encoding/json"
	"net/http"
)

// WriteJSON serializes v as JSON and writes it to the response with the
// given HTTP status code. Sets Content-Type to application/json.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// ErrorDetail carries optional fields for OpenAI-compatible error responses.
type ErrorDetail struct {
	param string // e.g. "model", "max_tokens"
	code  string // e.g. "model_not_found", "insufficient_quota"
}

// ErrorBody builds a standard OpenAI-compatible error response body.
// By default, code is inferred from errType. Callers can override code or
// set param via WithParam / WithCode helpers.
func ErrorBody(errType, message string, opts ...ErrorDetail) map[string]any {
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

// WithParam returns an option that sets the "param" field on an error response.
func WithParam(p string) ErrorDetail { return ErrorDetail{param: p} }

// WithCode returns an option that overrides the "code" field on an error response.
func WithCode(c string) ErrorDetail { return ErrorDetail{code: c} }
