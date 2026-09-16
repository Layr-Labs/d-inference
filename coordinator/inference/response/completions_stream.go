package response

import (
	"encoding/json"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
	"strings"
	"time"
)

type completionsStreamEmitter struct {
	observer     WriteObserver
	w            http.ResponseWriter
	flusher      http.Flusher
	pr           *registry.PendingRequest
	stamps       *relayStamps
	finishIndex  int
	finishReason string
}

func (e *completionsStreamEmitter) Start() {}

func (e *completionsStreamEmitter) Chunk(chunk string) {
	for _, choice := range parseStreamChunkChoices(chunk) {
		if choice.FinishReason != nil && *choice.FinishReason != "" {
			e.finishIndex = choice.Index
			e.finishReason = *choice.FinishReason
		}
		if choice.Delta.Content == "" {
			continue
		}
		e.emit(map[string]any{
			"id":      "cmpl-" + strings.ReplaceAll(e.pr.RequestID, "-", ""),
			"object":  "text_completion",
			"created": time.Now().Unix(),
			"model":   ConsumerModel(e.pr),
			"choices": []any{map[string]any{
				"index":         choice.Index,
				"text":          choice.Delta.Content,
				"logprobs":      nil,
				"finish_reason": nil,
			}},
		})
	}
}

func (e *completionsStreamEmitter) Finish(usage protocol.UsageInfo) {
	event := map[string]any{
		"id":      "cmpl-" + strings.ReplaceAll(e.pr.RequestID, "-", ""),
		"object":  "text_completion",
		"created": time.Now().Unix(),
		"model":   ConsumerModel(e.pr),
		"choices": []any{map[string]any{
			"index":         e.finishIndex,
			"text":          "",
			"logprobs":      nil,
			"finish_reason": genericFinishReason(e.finishReason, usage, e.pr.RequestedMaxTokens),
		}},
	}
	addResponseProof(event, e.pr)
	e.emit(event)
	n, werr := fmt.Fprint(e.w, "data: [DONE]\n\n")
	observeTerminalWrite(e.observer, e.w, Terminals{First: "completed"}, n, len("data: [DONE]\n\n"), werr)
	if n != len("data: [DONE]\n\n") {
		e.stamps.writeErr()
	}
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
	e.stamps.done()
}

func (e *completionsStreamEmitter) Error(kind, message string) {
	e.emit(map[string]any{"error": map[string]any{"type": kind, "message": message}})
}

func (e *completionsStreamEmitter) emit(value any) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return
	}
	n, werr := fmt.Fprintf(e.w, "data: %s\n\n", encoded)
	observeContentWrite(e.observer, e.w, GeneratedContentJSON(encoded), n, len(encoded)+8, werr)
	observeTerminalWrite(e.observer, e.w, responseEventTerminals(encoded), n, len(encoded)+8, werr)
	if n != len(encoded)+8 {
		e.stamps.writeErr()
	}
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
}
