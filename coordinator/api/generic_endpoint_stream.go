package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type completionsStreamEmitter struct {
	w            http.ResponseWriter
	flusher      http.Flusher
	pr           *registry.PendingRequest
	stamps       *relayStamps
	finishIndex  int
	finishReason string
}

func (e *completionsStreamEmitter) start() {}

func (e *completionsStreamEmitter) handleChunk(chunk string) {
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
			"model":   consumerModel(e.pr),
			"choices": []any{map[string]any{
				"index":         choice.Index,
				"text":          choice.Delta.Content,
				"logprobs":      nil,
				"finish_reason": nil,
			}},
		})
	}
}

func (e *completionsStreamEmitter) finish(usage protocol.UsageInfo) {
	event := map[string]any{
		"id":      "cmpl-" + strings.ReplaceAll(e.pr.RequestID, "-", ""),
		"object":  "text_completion",
		"created": time.Now().Unix(),
		"model":   consumerModel(e.pr),
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
	markResponseTerminalWrite(e.w, responseTerminals{first: "completed"}, n, len("data: [DONE]\n\n"), werr)
	if n != len("data: [DONE]\n\n") {
		e.stamps.writeErr()
	}
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
	e.stamps.done()
}

func (e *completionsStreamEmitter) emitError(kind, message string) {
	e.emit(map[string]any{"error": map[string]any{"type": kind, "message": message}})
}

func (e *completionsStreamEmitter) emit(value any) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return
	}
	n, werr := fmt.Fprintf(e.w, "data: %s\n\n", encoded)
	markContentWrite(e.w, generatedContentJSON(encoded), n, len(encoded)+8, werr)
	markResponseTerminalWrite(e.w, responseEventTerminals(encoded), n, len(encoded)+8, werr)
	if n != len(encoded)+8 {
		e.stamps.writeErr()
	}
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
}

type messagesStreamEmitter struct {
	stamps  *relayStamps
	w       http.ResponseWriter
	flusher http.Flusher
	pr      *registry.PendingRequest

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
) *messagesStreamEmitter {
	return &messagesStreamEmitter{
		stamps:    newRelayStamps(pr.Profile.Parent()),
		w:         w,
		flusher:   flusher,
		pr:        pr,
		messageID: "msg_" + strings.ReplaceAll(pr.RequestID, "-", ""),
		toolCalls: newToolCallAccumulator(),
	}
}

func (e *messagesStreamEmitter) start() {
	e.emit("message_start", map[string]any{
		"message": map[string]any{
			"id":            e.messageID,
			"type":          "message",
			"role":          "assistant",
			"model":         consumerModel(e.pr),
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

func (e *messagesStreamEmitter) handleChunk(chunk string) {
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

func (e *messagesStreamEmitter) finish(usage protocol.UsageInfo) {
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

func (e *messagesStreamEmitter) emitError(kind, message string) {
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
	markContentWrite(e.w, generatedContentJSON(encoded), n, len(eventType)+len(encoded)+16, werr)
	markResponseTerminalWrite(e.w, responseEventTerminals(encoded), n, len(eventType)+len(encoded)+16, werr)
	if n != len(eventType)+len(encoded)+16 {
		e.stamps.writeErr()
	}
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
}
