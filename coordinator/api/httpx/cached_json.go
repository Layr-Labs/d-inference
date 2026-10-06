package httpx

import (
	"encoding/json"
	"net/http"
)

// WriteCachedJSON writes pre-serialized JSON with the standard content type.
func WriteCachedJSON(w http.ResponseWriter, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// EncodeCachedJSON preserves WriteJSON's trailing newline and escaping so cache
// hits are byte-identical to the miss that populated them.
func EncodeCachedJSON(v any) ([]byte, error) {
	body, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return append(body, '\n'), nil
}
