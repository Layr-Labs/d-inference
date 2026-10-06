package response

import (
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type GenericEndpointStreamEmitter interface {
	Start()
	HandleChunk(string)
	Finish(protocol.UsageInfo)
	EmitError(string, string)
}

func NewGenericEndpointStreamEmitter(
	w http.ResponseWriter,
	flusher http.Flusher,
	pr *registry.PendingRequest,
) GenericEndpointStreamEmitter {
	if pr.ConsumerEndpoint == inreq.MessagesEndpoint {
		return newMessagesStreamEmitter(w, flusher, pr)
	}
	return &completionsStreamEmitter{w: w, flusher: flusher, pr: pr, stamps: observation.NewRelayStamps(pr.Profile.Parent())}
}

type completionsStreamEmitter struct {
	w            http.ResponseWriter
	flusher      http.Flusher
	pr           *registry.PendingRequest
	stamps       *observation.RelayStamps
	finishIndex  int
	finishReason string
}

func (e *completionsStreamEmitter) Start() {}

func (e *completionsStreamEmitter) HandleChunk(chunk string) {
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
		// The same usage object as the non-stream response, so a streamed
		// caller can reconcile a cache-read discount too.
		"usage": completionsUsage(usage),
	}
	addResponseProof(event, e.pr)
	e.emit(event)
	n, werr := fmt.Fprint(e.w, "data: [DONE]\n\n")
	observation.MarkResponseTerminalWrite(e.w, observation.Terminal("completed"), n, len("data: [DONE]\n\n"), werr)
	if n != len("data: [DONE]\n\n") {
		e.stamps.WriteErr()
	}
	e.flusher.Flush()
	e.stamps.Wrote(n, werr)
	e.stamps.Done()
}

func (e *completionsStreamEmitter) EmitError(kind, message string) {
	e.emit(map[string]any{"error": map[string]any{"type": kind, "message": message}})
}

type messagesStreamEmitter struct {
	stamps  *observation.RelayStamps
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
		stamps:    observation.NewRelayStamps(pr.Profile.Parent()),
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

func (e *messagesStreamEmitter) HandleChunk(chunk string) {
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
		// Anthropic's message_delta usage is cumulative and may carry the input
		// counts; message_start could not (usage is known only at the end).
		"usage": messagesUsage(usage),
	}
	addResponseProof(delta, e.pr)
	e.emit("message_delta", delta)
	e.emit("message_stop", map[string]any{})
	e.stamps.Done()
}

func (e *messagesStreamEmitter) closeOpenBlock() {
	if !e.contentOpen {
		return
	}
	e.emit("content_block_stop", map[string]any{"index": e.openIndex})
	e.contentOpen = false
}

func (e *messagesStreamEmitter) EmitError(kind, message string) {
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
