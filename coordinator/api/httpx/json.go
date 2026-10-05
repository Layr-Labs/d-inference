package httpx

// Small HTTP response helpers shared across the consumer/provider/billing
// handlers: JSON writing and the OpenAI-compatible error envelope.

import (
	"encoding/json"
	"errors"
	"net/http"
)

// WriteJSON serializes v as JSON and writes it to the response with the
// given HTTP status code. Sets Content-Type to application/json.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// ErrorDetailOpt carries optional fields for OpenAI-compatible error responses.
type ErrorDetailOpt struct {
	param string // e.g. "model", "max_tokens"
	code  string // e.g. "model_not_found", "insufficient_quota"
}

// ErrorResponse builds a standard OpenAI-compatible error response body.
// By default, code is inferred from errType. Callers can override code or
// set param via WithParam / WithCode helpers.
func ErrorResponse(errType, message string, opts ...ErrorDetailOpt) map[string]any {
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
func WithParam(p string) ErrorDetailOpt { return ErrorDetailOpt{param: p} }

// WithCode returns an option that overrides the "code" field on an error response.
func WithCode(c string) ErrorDetailOpt { return ErrorDetailOpt{code: c} }

// DecodeCappedJSON decodes the body under a hard cap, reporting 413 or 400 on failure.
func DecodeCappedJSON(w http.ResponseWriter, r *http.Request, maxBytes int64, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			WriteJSON(w, http.StatusRequestEntityTooLarge,
				ErrorResponse("invalid_request_error", "request body too large"))
			return false
		}
		WriteJSON(w, http.StatusBadRequest,
			ErrorResponse("invalid_request_error", "invalid JSON"))
		return false
	}
	return true
}
