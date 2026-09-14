package ingress

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
)

const maxInferenceBodyBytes = dispatch.MaxInferenceBodyBytes

// marshalForwardBody serializes a parsed request body for forwarding to a
// provider WITHOUT HTML escaping. encoding/json's default Marshal escapes the
// bytes '<', '>', and '&' into their 6-byte \uXXXX forms — a 6× per-character
// inflation that is meaningless on this path (the body is sealed and parsed as
// JSON by the provider, never embedded in HTML) yet can balloon a benign request
// — e.g. a prompt containing a long run of '<' — past the provider's
// single-frame WebSocket limit, tearing down its session. Disabling escaping
// keeps the re-marshaled body within a small constant of the (already
// size-capped) input. Mirrors toolpolicy.NormalizeBytes's own non-escaping round-trip.
func marshalForwardBody(v any) ([]byte, error) { return httpresponse.MarshalBody(v) }

// forwardBody is the provider-bound request as the handler reshapes it: the
// decoded map every rewrite is applied to, plus the bytes that map was last
// serialized to. bytes starts as the caller's verbatim input, so a request
// that needs no rewrite at all reaches the provider byte-for-byte as sent;
// after any mutation the handler marks the body dirty and current() serializes
// once, however many rewrites preceded it.
type forwardBody struct {
	parsed map[string]any
	bytes  []byte
	dirty  bool
	// serialized reports that bytes is a coordinator serialization of parsed
	// (marshalForwardBody output) rather than the caller's verbatim input. Only
	// such bytes may stand in for a candidateProviderBody: a verbatim body can
	// differ from its re-serialization in whitespace, key order and string
	// escapes, and the size verdicts must keep measuring the serialized form.
	serialized bool
}

// markDirty records that parsed has diverged from bytes.
func (b *forwardBody) markDirty() { b.dirty = true }

// current returns bytes reflecting every mutation so far, serializing only when
// something changed since the last serialization (or since the input was read).
func (b *forwardBody) current() ([]byte, error) {
	if !b.dirty {
		return b.bytes, nil
	}
	out, err := marshalForwardBody(b.parsed)
	if err != nil {
		return nil, err
	}
	b.bytes, b.dirty, b.serialized = out, false, true
	return out, nil
}

// replace adopts bytes a helper already serialized from parsed (remote media
// inlining re-marshals after mutating parsed in place).
func (b *forwardBody) replace(serialized []byte) {
	b.bytes, b.dirty, b.serialized = serialized, false, true
}

// parseJSONBody unmarshals the request body, writing the standard invalid-JSON
// error and returning ok=false on failure. Split out so both the prelude and any
// re-parse site share one error shape.
func parseJSONBody(w http.ResponseWriter, rawBody []byte) (map[string]any, bool) {
	parsed, err := decodeInferenceJSONObject(rawBody)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return nil, false
	}
	return parsed, true
}

func decodeInferenceJSONObject(rawBody []byte) (map[string]any, error) {
	return dispatch.DecodeJSONObject(rawBody)
}
