package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func stripProviderChatMetadataJSON(raw string) (string, bool) {
	var obj map[string]any
	if json.Unmarshal([]byte(raw), &obj) != nil {
		return raw, false
	}
	if _, exists := obj["metadata"]; !exists {
		return raw, false
	}
	delete(obj, "metadata")
	sanitized, err := marshalForwardBody(obj)
	if err != nil {
		return raw, false
	}
	return string(sanitized), true
}

// stripProviderChatMetadata reserves the top-level metadata field for the
// coordinator. Provider-originated chat chunks may carry arbitrary additive
// fields, so every matching SSE event is parsed and stripped before relay.
func stripProviderChatMetadata(chunk string) string {
	// The normal key takes the literal fast path. A disguised equivalent must
	// contain a JSON Unicode escape, which is parsed on the uncommon slow path.
	if !strings.Contains(chunk, `"metadata"`) && !strings.Contains(chunk, `\u`) {
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
