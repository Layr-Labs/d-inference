package httpresponse

import (
	"encoding/json"
	"net/http"
)

// WriteCachedJSON writes pre-serialized JSON bytes with the standard
// Content-Type header. Used on cache hit to skip json.Marshal.
func WriteCachedJSON(w http.ResponseWriter, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// EncodeCachedJSON renders v exactly as WriteJSON does (json.Encoder appends
// a trailing newline to the compact encoding), so a cache hit served by
// WriteCachedJSON is byte-identical to the miss that populated it.
func EncodeCachedJSON(v any) ([]byte, error) {
	body, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return append(body, '\n'), nil
}
