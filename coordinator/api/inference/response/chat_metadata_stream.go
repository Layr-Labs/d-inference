package response

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func NewChatCompletionExtrasEvent(pr *registry.PendingRequest, identities ...ChatStreamIdentity) map[string]any {
	id, created := "chatcmpl-"+pr.RequestID, time.Now().Unix()
	if len(identities) > 0 && identities[0].id != "" {
		id = identities[0].id
		if identities[0].created != nil {
			created = *identities[0].created
		}
	}
	return map[string]any{
		"id":      id,
		"object":  "chat.completion.chunk",
		"created": created,
		"model":   ConsumerModel(pr),
		"choices": []any{},
	}
}

// writeChatStreamTerminalError emits the authoritative metadata event before
// an in-band error so opt-in callers retain commit details on failed streams.
func WriteChatStreamTerminalError(
	w http.ResponseWriter,
	flusher http.Flusher,
	pr *registry.PendingRequest,
	errorType string,
	message string,
	identities ...ChatStreamIdentity,
) {
	if HasChatCompletionMetadata(pr) {
		event := NewChatCompletionExtrasEvent(pr, identities...)
		AttachChatCompletionMetadata(event, pr)
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
	n, err := fmt.Fprintf(w, "data: %s\n\n", errData)
	observation.MarkResponseTerminalWrite(w, observation.Terminal("error"), n, len(errData)+8, err)
	flusher.Flush()
}
