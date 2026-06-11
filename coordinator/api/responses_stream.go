package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// streamToolCallDelta is one tool-call fragment from a chat.completion.chunk.
type streamToolCallDelta struct {
	Index    int    `json:"index"`
	ID       string `json:"id,omitempty"`
	Type     string `json:"type,omitempty"`
	Function struct {
		Name      string `json:"name,omitempty"`
		Arguments string `json:"arguments,omitempty"`
	} `json:"function,omitempty"`
}

// streamChunkChoice is a parsed choice from a chat.completion.chunk SSE line.
type streamChunkChoice struct {
	Delta struct {
		Content          string                `json:"content"`
		Reasoning        string                `json:"reasoning"`
		ReasoningContent string                `json:"reasoning_content"`
		ToolCalls        []streamToolCallDelta `json:"tool_calls,omitempty"`
	} `json:"delta"`
	FinishReason *string `json:"finish_reason"`
}

// parseStreamChunkChoices decodes the choices array from a provider SSE chunk.
// Returns nil for non-JSON lines, [DONE], and chunks without choices.
func parseStreamChunkChoices(chunk string) []streamChunkChoice {
	line := strings.TrimSpace(strings.TrimPrefix(chunk, "data: "))
	if line == "" || line == "[DONE]" {
		return nil
	}
	var parsed struct {
		Choices []streamChunkChoice `json:"choices"`
	}
	if err := json.Unmarshal([]byte(line), &parsed); err != nil {
		return nil
	}
	return parsed.Choices
}

// responsesSnapshot builds the full Response object embedded in lifecycle
// events (response.created / response.in_progress / response.completed /
// response.incomplete). All spec-required fields are present so strict SDK
// parsers accept the snapshot.
func responsesSnapshot(responseID string, createdAt int64, model, status string, output []any, usage *types.ResponsesUsage, incomplete *types.ResponsesIncompleteDetail) map[string]any {
	if output == nil {
		output = []any{}
	}
	snap := map[string]any{
		"id":                   responseID,
		"object":               "response",
		"created_at":           createdAt,
		"status":               status,
		"background":           false,
		"error":                nil,
		"incomplete_details":   nil,
		"instructions":         nil,
		"max_output_tokens":    nil,
		"model":                model,
		"output":               output,
		"parallel_tool_calls":  true,
		"previous_response_id": nil,
		"store":                false,
		"temperature":          nil,
		"text":                 map[string]any{"format": map[string]any{"type": "text"}},
		"tool_choice":          "auto",
		"tools":                []any{},
		"top_p":                nil,
		"truncation":           "disabled",
		"usage":                nil,
		"user":                 nil,
		"metadata":             map[string]any{},
		"service_tier":         nil,
	}
	if usage != nil {
		snap["usage"] = usage
	}
	if incomplete != nil {
		snap["incomplete_details"] = incomplete
	}
	return snap
}

// responsesStreamEmitter translates provider chat.completion.chunk deltas into
// incremental OpenAI Responses API SSE events. Every event carries an `event:`
// line and a monotonically increasing sequence_number, matching the official
// Responses streaming wire format.
type responsesStreamEmitter struct {
	w       http.ResponseWriter
	flusher http.Flusher
	pr      *registry.PendingRequest

	responseID string
	createdAt  int64
	model      string
	seq        int

	outputIndex int
	output      []any

	reasoningOpen   bool
	reasoningItemID string
	reasoningBuf    strings.Builder

	messageOpen   bool
	messageItemID string
	contentBuf    strings.Builder

	fnOpen    bool
	fnIndex   int
	fnItemID  string
	fnCallID  string
	fnName    string
	fnArgsBuf strings.Builder

	finishReason string
}

func newResponsesStreamEmitter(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest, responseID string, createdAt int64) *responsesStreamEmitter {
	return &responsesStreamEmitter{
		w:          w,
		flusher:    flusher,
		pr:         pr,
		responseID: responseID,
		createdAt:  createdAt,
		model:      consumerModel(pr),
	}
}

// emit writes one SSE event with an `event:` line and a sequence_number.
func (e *responsesStreamEmitter) emit(eventType string, fields map[string]any) {
	fields["type"] = eventType
	fields["sequence_number"] = e.seq
	e.seq++
	data, err := json.Marshal(fields)
	if err != nil {
		return
	}
	fmt.Fprintf(e.w, "event: %s\ndata: %s\n\n", eventType, data)
	e.flusher.Flush()
}

// start emits response.created and response.in_progress.
func (e *responsesStreamEmitter) start() {
	e.emit("response.created", map[string]any{
		"response": responsesSnapshot(e.responseID, e.createdAt, e.model, "in_progress", nil, nil, nil),
	})
	e.emit("response.in_progress", map[string]any{
		"response": responsesSnapshot(e.responseID, e.createdAt, e.model, "in_progress", nil, nil, nil),
	})
}

// handleChunk translates one provider SSE chunk into incremental events.
func (e *responsesStreamEmitter) handleChunk(chunk string) {
	for _, c := range parseStreamChunkChoices(chunk) {
		if c.FinishReason != nil && *c.FinishReason != "" {
			e.finishReason = *c.FinishReason
		}
		reasoning := c.Delta.Reasoning
		if reasoning == "" {
			reasoning = c.Delta.ReasoningContent
		}
		if reasoning != "" {
			e.appendReasoning(reasoning)
		}
		if c.Delta.Content != "" {
			e.appendContent(c.Delta.Content)
		}
		for _, tc := range c.Delta.ToolCalls {
			e.appendToolCall(tc)
		}
	}
}

func (e *responsesStreamEmitter) appendReasoning(delta string) {
	if !e.reasoningOpen {
		e.closeOpenItems()
		e.reasoningOpen = true
		e.reasoningItemID = responseItemID("rs", e.pr.RequestID, e.outputIndex)
		e.emit("response.output_item.added", map[string]any{
			"output_index": e.outputIndex,
			"item": map[string]any{
				"type":    "reasoning",
				"id":      e.reasoningItemID,
				"summary": []any{},
				"status":  "in_progress",
			},
		})
		e.emit("response.reasoning_summary_part.added", map[string]any{
			"item_id":       e.reasoningItemID,
			"output_index":  e.outputIndex,
			"summary_index": 0,
			"part":          map[string]any{"type": "summary_text", "text": ""},
		})
	}
	e.reasoningBuf.WriteString(delta)
	e.emit("response.reasoning_summary_text.delta", map[string]any{
		"item_id":       e.reasoningItemID,
		"output_index":  e.outputIndex,
		"summary_index": 0,
		"delta":         delta,
	})
}

func (e *responsesStreamEmitter) closeReasoning() {
	if !e.reasoningOpen {
		return
	}
	text := e.reasoningBuf.String()
	e.emit("response.reasoning_summary_text.done", map[string]any{
		"item_id":       e.reasoningItemID,
		"output_index":  e.outputIndex,
		"summary_index": 0,
		"text":          text,
	})
	e.emit("response.reasoning_summary_part.done", map[string]any{
		"item_id":       e.reasoningItemID,
		"output_index":  e.outputIndex,
		"summary_index": 0,
		"part":          map[string]any{"type": "summary_text", "text": text},
	})
	item := map[string]any{
		"type":    "reasoning",
		"id":      e.reasoningItemID,
		"summary": []any{map[string]any{"type": "summary_text", "text": text}},
		"status":  "completed",
	}
	e.emit("response.output_item.done", map[string]any{
		"output_index": e.outputIndex,
		"item":         item,
	})
	e.output = append(e.output, item)
	e.outputIndex++
	e.reasoningOpen = false
}

func (e *responsesStreamEmitter) appendContent(delta string) {
	if !e.messageOpen {
		e.closeReasoning()
		e.closeFunctionCall()
		e.messageOpen = true
		e.messageItemID = responseItemID("msg", e.pr.RequestID, e.outputIndex)
		e.emit("response.output_item.added", map[string]any{
			"output_index": e.outputIndex,
			"item": map[string]any{
				"type":    "message",
				"id":      e.messageItemID,
				"role":    "assistant",
				"content": []any{},
				"status":  "in_progress",
			},
		})
		e.emit("response.content_part.added", map[string]any{
			"item_id":       e.messageItemID,
			"output_index":  e.outputIndex,
			"content_index": 0,
			"part":          map[string]any{"type": "output_text", "text": "", "annotations": []any{}},
		})
	}
	e.contentBuf.WriteString(delta)
	e.emit("response.output_text.delta", map[string]any{
		"item_id":       e.messageItemID,
		"output_index":  e.outputIndex,
		"content_index": 0,
		"delta":         delta,
		"logprobs":      []any{},
	})
}

func (e *responsesStreamEmitter) closeMessage() {
	if !e.messageOpen {
		return
	}
	text := e.contentBuf.String()
	e.emit("response.output_text.done", map[string]any{
		"item_id":       e.messageItemID,
		"output_index":  e.outputIndex,
		"content_index": 0,
		"text":          text,
		"logprobs":      []any{},
	})
	e.emit("response.content_part.done", map[string]any{
		"item_id":       e.messageItemID,
		"output_index":  e.outputIndex,
		"content_index": 0,
		"part":          map[string]any{"type": "output_text", "text": text, "annotations": []any{}},
	})
	item := map[string]any{
		"type": "message",
		"id":   e.messageItemID,
		"role": "assistant",
		"content": []any{map[string]any{
			"type":        "output_text",
			"text":        text,
			"annotations": []any{},
		}},
		"status": "completed",
	}
	e.emit("response.output_item.done", map[string]any{
		"output_index": e.outputIndex,
		"item":         item,
	})
	e.output = append(e.output, item)
	e.outputIndex++
	e.messageOpen = false
}

func (e *responsesStreamEmitter) appendToolCall(tc streamToolCallDelta) {
	if e.fnOpen && tc.Index != e.fnIndex {
		e.closeFunctionCall()
	}
	if !e.fnOpen {
		e.closeReasoning()
		e.closeMessage()
		e.fnOpen = true
		e.fnIndex = tc.Index
		e.fnItemID = responseItemID("fc", e.pr.RequestID, e.outputIndex)
		e.fnCallID = tc.ID
		if e.fnCallID == "" {
			e.fnCallID = responseItemID("call", e.pr.RequestID, e.outputIndex)
		}
		e.fnName = tc.Function.Name
		e.fnArgsBuf.Reset()
		e.emit("response.output_item.added", map[string]any{
			"output_index": e.outputIndex,
			"item": map[string]any{
				"type":      "function_call",
				"id":        e.fnItemID,
				"call_id":   e.fnCallID,
				"name":      e.fnName,
				"arguments": "",
				"status":    "in_progress",
			},
		})
	}
	if tc.ID != "" {
		e.fnCallID = tc.ID
	}
	if tc.Function.Name != "" {
		e.fnName = tc.Function.Name
	}
	if tc.Function.Arguments != "" {
		e.fnArgsBuf.WriteString(tc.Function.Arguments)
		e.emit("response.function_call_arguments.delta", map[string]any{
			"item_id":      e.fnItemID,
			"output_index": e.outputIndex,
			"delta":        tc.Function.Arguments,
		})
	}
}

func (e *responsesStreamEmitter) closeFunctionCall() {
	if !e.fnOpen {
		return
	}
	args := e.fnArgsBuf.String()
	e.emit("response.function_call_arguments.done", map[string]any{
		"item_id":      e.fnItemID,
		"output_index": e.outputIndex,
		"arguments":    args,
	})
	item := map[string]any{
		"type":      "function_call",
		"id":        e.fnItemID,
		"call_id":   e.fnCallID,
		"name":      e.fnName,
		"arguments": args,
		"status":    "completed",
	}
	e.emit("response.output_item.done", map[string]any{
		"output_index": e.outputIndex,
		"item":         item,
	})
	e.output = append(e.output, item)
	e.outputIndex++
	e.fnOpen = false
}

func (e *responsesStreamEmitter) closeOpenItems() {
	e.closeReasoning()
	e.closeMessage()
	e.closeFunctionCall()
}

// hasToolCalls reports whether at least one function_call item was emitted.
func (e *responsesStreamEmitter) hasToolCalls() bool {
	if e.fnOpen {
		return true
	}
	for _, item := range e.output {
		if m, ok := item.(map[string]any); ok && m["type"] == "function_call" {
			return true
		}
	}
	return false
}

// finish closes all open items and emits the terminal lifecycle event
// (response.completed, or response.incomplete when generation was truncated).
func (e *responsesStreamEmitter) finish(usage protocol.UsageInfo) {
	finishReason := effectiveFinishReason(e.finishReason, e.hasToolCalls(), usage, e.pr.RequestedMaxTokens)
	e.closeOpenItems()

	reasoningTokens := resolveReasoningTokens(usage, e.reasoningBuf.String())
	u := buildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens)

	status := "completed"
	eventType := "response.completed"
	incomplete := buildResponsesIncompleteDetails(finishReason)
	if incomplete != nil {
		status = "incomplete"
		eventType = "response.incomplete"
	}
	snap := responsesSnapshot(e.responseID, e.createdAt, e.model, status, e.output, &u, incomplete)
	if e.pr.SESignature != "" {
		snap["se_signature"] = e.pr.SESignature
		snap["response_hash"] = e.pr.ResponseHash
	}
	e.emit(eventType, map[string]any{"response": snap})
}

// emitError emits a Responses-API error event.
func (e *responsesStreamEmitter) emitError(errType, message string) {
	e.emit("error", map[string]any{
		"error": map[string]any{
			"type":    errType,
			"code":    errType,
			"message": message,
			"param":   nil,
		},
	})
}
