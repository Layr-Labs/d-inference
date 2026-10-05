package sse

import (
	"encoding/json"
	"io"
	"strings"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func stripProviderChatMetadataJSON(raw string) (string, bool) {
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	var obj map[string]any
	if err := decoder.Decode(&obj); err != nil {
		// This function is reached only for a frame that contains either the
		// reserved key or a JSON Unicode escape. Never relay a suspicious frame
		// that the coordinator cannot parse but a more permissive client might.
		return "", true
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return "", true
	}
	before := len(obj)
	DeleteChatCompletionMetadata(obj)
	if len(obj) == before {
		return raw, false
	}
	sanitized, err := inreq.MarshalForwardBody(obj)
	if err != nil {
		return "", true
	}
	return string(sanitized), true
}

func containsChatMetadataKeyToken(raw string) bool {
	const maxFoldedKeyBytes = 4 * len(ChatCompletionMetadataField)
	start := strings.IndexByte(raw, '"')
	for start >= 0 {
		raw = raw[start+1:]
		end := strings.IndexByte(raw, '"')
		if end < 0 {
			return false
		}
		if end <= maxFoldedKeyBytes && strings.EqualFold(raw[:end], ChatCompletionMetadataField) {
			return true
		}
		// Every quote can start the next candidate, including the closing
		// quote just examined. Pairing quotes would miss a key following an
		// unmatched quote in an SSE comment. The reserved key contains no
		// quotes or newlines, so only adjacent quotes can enclose a match.
		start = end
	}
	return false
}

// stripProviderChatMetadata reserves the top-level metadata field for the
// coordinator. Provider-originated chat chunks may carry arbitrary additive
// fields, so every matching SSE event is parsed and stripped before relay.
func StripProviderChatMetadata(chunk string) string {
	// Case variants take the allocation-free quoted-token scan. An escaped
	// equivalent contains a JSON Unicode escape and is parsed on the uncommon
	// slow path.
	if !containsChatMetadataKeyToken(chunk) && !strings.Contains(chunk, `\u`) {
		return chunk
	}
	return SanitizeStreamJSONEvents(chunk, stripProviderChatMetadataJSON)
}
