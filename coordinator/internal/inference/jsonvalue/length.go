package jsonvalue

import "encoding/json"

// Len returns len(json.Marshal(v)), counting decoder-shaped values without
// allocating the encoding and marshaling anything else. A value the encoder
// rejects reports 0, exactly as the marshal-and-measure path did.
func Len(v any) int {
	if n, ok := EncodedLen(v); ok {
		return n
	}
	b, err := json.Marshal(v)
	if err != nil {
		return 0
	}
	return len(b)
}
