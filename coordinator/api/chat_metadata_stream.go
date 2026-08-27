package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
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
	deleteChatCompletionMetadata(obj)
	if len(obj) == before {
		return raw, false
	}
	sanitized, err := marshalForwardBody(obj)
	if err != nil {
		return "", true
	}
	return string(sanitized), true
}

func containsChatMetadataKeyToken(raw string) bool {
	for searchFrom := 0; searchFrom < len(raw); {
		relativeStart := strings.IndexByte(raw[searchFrom:], '"')
		if relativeStart < 0 {
			return false
		}
		start := searchFrom + relativeStart + 1
		end := start
		for end < len(raw) && raw[end] != '"' {
			if raw[end] == '\\' {
				end++
			}
			end++
		}
		if end >= len(raw) {
			return false
		}
		if strings.EqualFold(raw[start:end], chatCompletionMetadataField) {
			return true
		}
		searchFrom = end + 1
	}
	return false
}

// stripProviderChatMetadata reserves the top-level metadata field for the
// coordinator. Provider-originated chat chunks may carry arbitrary additive
// fields, so every matching SSE event is parsed and stripped before relay.
func stripProviderChatMetadata(chunk string) string {
	// Case variants take the allocation-free quoted-token scan. An escaped
	// equivalent contains a JSON Unicode escape and is parsed on the uncommon
	// slow path.
	if !containsChatMetadataKeyToken(chunk) && !strings.Contains(chunk, `\u`) {
		return chunk
	}
	normalized := strings.ReplaceAll(strings.ReplaceAll(chunk, "\r\n", "\n"), "\r", "\n")
	groups := strings.Split(normalized, "\n\n")
	changed := false
	for i, group := range groups {
		if sanitized, ok := sanitizeStreamJSONEventGroup(group, stripProviderChatMetadataJSON); ok {
			groups[i] = sanitized
			changed = true
		}
	}
	if changed {
		return strings.Join(groups, "\n\n")
	}
	return chunk
}

func newChatCompletionExtrasEvent(pr *registry.PendingRequest) map[string]any {
	return map[string]any{
		"id":      "chatcmpl-" + pr.RequestID,
		"object":  "chat.completion.chunk",
		"created": time.Now().Unix(),
		"model":   consumerModel(pr),
		"choices": []any{},
	}
}

// writeChatStreamTerminalError emits the authoritative metadata event before
// an in-band error so opt-in callers retain commit details on failed streams.
func (s *Server) writeChatStreamTerminalError(
	w http.ResponseWriter,
	flusher http.Flusher,
	pr *registry.PendingRequest,
	errorType string,
	message string,
) {
	if hasChatCompletionMetadata(pr) {
		event := newChatCompletionExtrasEvent(pr)
		attachChatCompletionMetadata(event, pr)
		if metadataEvent, err := json.Marshal(event); err == nil {
			fmt.Fprintf(w, "data: %s\n\n", metadataEvent)
		}
	}
	errData, _ := json.Marshal(map[string]any{
		"error": map[string]any{
			"message": message,
			"type":    errorType,
		},
	})
	fmt.Fprintf(w, "data: %s\n\n", errData)
	flusher.Flush()
}
