package httpresponse

import (
	"bytes"
	"encoding/json"
)

// MarshalBody serializes a wire body without HTML escaping or a trailing newline.
// Unlike EncodeCachedJSON, it preserves literal <, > and & bytes.
func MarshalBody(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	// Encoder.Encode appends a trailing newline the encrypted body shouldn't carry.
	return bytes.TrimSuffix(buf.Bytes(), []byte{'\n'}), nil
}
