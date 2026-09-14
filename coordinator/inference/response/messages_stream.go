package response

import (
	"encoding/json"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"log"
	"net/http"
	"strings"
)

type messagesStreamEmitter struct {
	observer WriteObserver
	stamps   *relayStamps
	w        http.ResponseWriter
	flusher  http.Flusher
	pr       *registry.PendingRequest

	messageID    string
	nextIndex    int
	openIndex    int
	contentOpen  bool
	finishReason string
	toolCalls    *toolCallAccumulator
}

func newMessagesStreamEmitter(
	w http.ResponseWriter,
	flusher http.Flusher,
	pr *registry.PendingRequest,
	observer WriteObserver,
) *messagesStreamEmitter {
	return &messagesStreamEmitter{observer: observer,
		stamps:    newRelayStamps(pr.Profile.Parent()),
		w:         w,
		flusher:   flusher,
		pr:        pr,
		messageID: "msg_" + strings.ReplaceAll(pr.RequestID, "-", ""),
		toolCalls: newToolCallAccumulator(),
	}
}

func (e *messagesStreamEmitter) Start() {
	e.emit("message_start", map[string]any{
		"message": map[string]any{
			"id":            e.messageID,
			"type":          "message",
			"role":          "assistant",
			"model":         ConsumerModel(e.pr),
			"content":       []any{},
			"stop_reason":   nil,
			"stop_sequence": nil,
			"usage": map[string]any{
				"input_tokens":  0,
				"output_tokens": 0,
			},
		},
	})
}

func (e *messagesStreamEmitter) Chunk(chunk string) {
	for _, choice := range parseStreamChunkChoices(chunk) {
		if choice.FinishReason != nil && *choice.FinishReason != "" {
			e.finishReason = *choice.FinishReason
		}
		if choice.Delta.Content != "" {
			e.appendContent(choice.Delta.Content)
		}
		for _, fragment := range choice.Delta.ToolCalls {
			e.toolCalls.apply(fragment)
		}
	}
}

func (e *messagesStreamEmitter) appendContent(value string) {
	if !e.contentOpen {
		e.contentOpen = true
		e.openIndex = e.nextIndex
		e.nextIndex++
		e.emit("content_block_start", map[string]any{
			"index":         e.openIndex,
			"content_block": map[string]any{"type": "text", "text": ""},
		})
	}
	e.emit("content_block_delta", map[string]any{
		"index": e.openIndex,
		"delta": map[string]any{"type": "text_delta", "text": value},
	})
}

func (e *messagesStreamEmitter) Finish(usage protocol.UsageInfo) {
	e.closeOpenBlock()
	if e.toolCalls.droppedDeltas > 0 {
		log.Printf("WARN: messages stream: logical tool-call cap (%d) reached; dropped %d tool-call delta(s) from excess calls",
			maxLogicalToolCalls, e.toolCalls.droppedDeltas)
	}
	for _, call := range e.toolCalls.finalize() {
		id, _ := call["id"].(string)
		function, _ := call["function"].(map[string]any)
		name, _ := function["name"].(string)
		arguments, _ := function["arguments"].(string)
		contentIndex := e.nextIndex
		e.nextIndex++
		e.emit("content_block_start", map[string]any{
			"index": contentIndex,
			"content_block": map[string]any{
				"type":  "tool_use",
				"id":    id,
				"name":  name,
				"input": map[string]any{},
			},
		})
		if arguments != "" {
			e.emit("content_block_delta", map[string]any{
				"index": contentIndex,
				"delta": map[string]any{
					"type":         "input_json_delta",
					"partial_json": arguments,
				},
			})
		}
		e.emit("content_block_stop", map[string]any{"index": contentIndex})
	}
	stopReason, stopSequence := messagesStopOutcome(
		e.finishReason, usage, e.pr.RequestedMaxTokens, e.pr.MatchedStopSequence)
	delta := map[string]any{
		"delta": map[string]any{
			"stop_reason":   stopReason,
			"stop_sequence": stopSequence,
		},
		"usage": map[string]any{"output_tokens": usage.CompletionTokens},
	}
	addResponseProof(delta, e.pr)
	e.emit("message_delta", delta)
	e.emit("message_stop", map[string]any{})
	e.stamps.done()
}

func (e *messagesStreamEmitter) closeOpenBlock() {
	if !e.contentOpen {
		return
	}
	e.emit("content_block_stop", map[string]any{"index": e.openIndex})
	e.contentOpen = false
}

func (e *messagesStreamEmitter) Error(kind, message string) {
	switch kind {
	case "timeout":
		kind = "overloaded_error"
	default:
		kind = "api_error"
	}
	e.emit("error", map[string]any{
		"error": map[string]any{"type": kind, "message": message},
	})
}

func (e *messagesStreamEmitter) emit(eventType string, fields map[string]any) {
	fields["type"] = eventType
	encoded, err := json.Marshal(fields)
	if err != nil {
		return
	}
	n, werr := fmt.Fprintf(e.w, "event: %s\ndata: %s\n\n", eventType, encoded)
	observeContentWrite(e.observer, e.w, GeneratedContentJSON(encoded), n, len(eventType)+len(encoded)+16, werr)
	observeTerminalWrite(e.observer, e.w, responseEventTerminals(encoded), n, len(eventType)+len(encoded)+16, werr)
	if n != len(eventType)+len(encoded)+16 {
		e.stamps.writeErr()
	}
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
}
