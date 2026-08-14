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
	Index int `json:"index"`
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
func responsesSnapshot(responseID string, createdAt int64, model, status string, output []any, usage *types.ResponsesUsage, incomplete *types.ResponsesIncompleteDetail, policies ...registry.RequestTraits) map[string]any {
	if output == nil {
		output = []any{}
	}
	var traits registry.RequestTraits
	if len(policies) > 0 {
		traits = policies[0]
	}
	toolChoice, parallel := responsesToolPolicy(traits)
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
		"parallel_tool_calls":  parallel,
		"previous_response_id": nil,
		"store":                false,
		"temperature":          nil,
		"text":                 map[string]any{"format": map[string]any{"type": "text"}},
		"tool_choice":          toolChoice,
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

func responsesToolPolicy(traits registry.RequestTraits) (any, bool) {
	if traits.ToolChoiceMode == "" {
		return "auto", true
	}
	switch traits.ToolChoiceMode {
	case string(toolChoiceNone):
		return "none", traits.ParallelToolCalls
	case string(toolChoiceRequired):
		return "required", traits.ParallelToolCalls
	case string(toolChoiceNamed):
		return map[string]any{
			"type": "function",
			"name": traits.ToolChoiceName,
		}, traits.ParallelToolCalls
	default:
		return "auto", traits.ParallelToolCalls
	}
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

	activeFnByIndex map[int]*streamFnState
	fnOrder         []*streamFnState
	sawToolCall     bool

	finishReason string
}

// streamFnState tracks one in-progress function_call output item, keyed by
// the provider chunk's tool_calls[].index.
type streamFnState struct {
	outputIndex int
	itemID      string
	callID      string
	wireID      string
	name        string
	argsBuf     strings.Builder
}

func newResponsesStreamEmitter(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest, responseID string, createdAt int64) *responsesStreamEmitter {
	return &responsesStreamEmitter{
		w:               w,
		flusher:         flusher,
		pr:              pr,
		responseID:      responseID,
		createdAt:       createdAt,
		model:           consumerModel(pr),
		activeFnByIndex: map[int]*streamFnState{},
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
		"response": responsesSnapshot(e.responseID, e.createdAt, e.model, "in_progress", nil, nil, nil, e.pr.Traits),
	})
	e.emit("response.in_progress", map[string]any{
		"response": responsesSnapshot(e.responseID, e.createdAt, e.model, "in_progress", nil, nil, nil, e.pr.Traits),
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
			if e.pr.SuppressReasoning {
				// Reasoning was disabled or excluded: no reasoning item or
				// summary event ever reaches the consumer. The text is still
				// buffered so finish()'s resolveReasoningTokens keeps its
				// legacy text-based fallback — exclude hides reasoning, it
				// doesn't unbill it.
				e.reasoningBuf.WriteString(reasoning)
			} else {
				e.appendReasoning(reasoning)
			}
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
	e.ensureMessageOpen()
	e.contentBuf.WriteString(delta)
	e.emit("response.output_text.delta", map[string]any{
		"item_id":       e.messageItemID,
		"output_index":  e.outputIndex,
		"content_index": 0,
		"delta":         delta,
		"logprobs":      []any{},
	})
}

func (e *responsesStreamEmitter) ensureMessageOpen() {
	if !e.messageOpen {
		e.closeReasoning()
		e.closeFunctionCalls()
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

// appendToolCall routes one tool_calls[] fragment to its function_call item.
// Provider chunks key fragments by a stable tool_calls[].index, and fragments
// for several calls may interleave, so each index gets its own item state and
// reserved output_index.
func (e *responsesStreamEmitter) appendToolCall(tc streamToolCallDelta) {
	st := e.activeFnByIndex[tc.Index]
	// Legacy provider builds emit every parallel call at wire index 0 (the
	// engine at this branch's pin assigns distinct indices — see
	// MLXOpenAIService.nextToolCallIndex — but the fleet updates slowly). A
	// different non-empty ID on an active index starts a new logical call;
	// later ID-less argument fragments continue the newest call. This is the
	// same identity rule used by the non-streaming toolCallAccumulator.
	if st != nil && tc.ID != "" && st.wireID != "" && tc.ID != st.wireID {
		st = nil
	}
	if st == nil {
		// Same cap as the non-streaming accumulator: past the limit the new
		// logical call is dropped and its wire index forgotten, so the
		// dropped call's later id-less fragments can never accumulate onto
		// a kept call (they re-enter here and are dropped again).
		if len(e.fnOrder) >= maxLogicalToolCalls {
			delete(e.activeFnByIndex, tc.Index)
			return
		}
		e.closeReasoning()
		e.closeMessage()
		e.sawToolCall = true
		st = &streamFnState{outputIndex: e.outputIndex, wireID: tc.ID}
		e.outputIndex++
		st.itemID = responseItemID("fc", e.pr.RequestID, st.outputIndex)
		st.callID = tc.ID
		if st.callID == "" {
			st.callID = responseItemID("call", e.pr.RequestID, st.outputIndex)
		}
		st.name = tc.Function.Name
		e.activeFnByIndex[tc.Index] = st
		e.fnOrder = append(e.fnOrder, st)
		e.emit("response.output_item.added", map[string]any{
			"output_index": st.outputIndex,
			"item": map[string]any{
				"type":      "function_call",
				"id":        st.itemID,
				"call_id":   st.callID,
				"name":      st.name,
				"arguments": "",
				"status":    "in_progress",
			},
		})
	}
	if tc.ID != "" {
		st.wireID = tc.ID
		st.callID = tc.ID
	}
	if tc.Function.Name != "" {
		st.name = tc.Function.Name
	}
	if tc.Function.Arguments != "" {
		st.argsBuf.WriteString(tc.Function.Arguments)
		e.emit("response.function_call_arguments.delta", map[string]any{
			"item_id":      st.itemID,
			"output_index": st.outputIndex,
			"delta":        tc.Function.Arguments,
		})
	}
}

// closeFunctionCalls finalizes all open function_call items in the order they
// were opened, which matches their reserved output indexes.
func (e *responsesStreamEmitter) closeFunctionCalls() {
	for _, state := range e.fnOrder {
		e.closeFunctionCall(state)
	}
	e.fnOrder = nil
	clear(e.activeFnByIndex)
}

func (e *responsesStreamEmitter) closeFunctionCall(st *streamFnState) {
	args := st.argsBuf.String()
	e.emit("response.function_call_arguments.done", map[string]any{
		"item_id":      st.itemID,
		"output_index": st.outputIndex,
		"arguments":    args,
	})
	item := map[string]any{
		"type":      "function_call",
		"id":        st.itemID,
		"call_id":   st.callID,
		"name":      st.name,
		"arguments": args,
		"status":    "completed",
	}
	e.emit("response.output_item.done", map[string]any{
		"output_index": st.outputIndex,
		"item":         item,
	})
	e.output = append(e.output, item)
}

func (e *responsesStreamEmitter) closeOpenItems() {
	e.closeReasoning()
	e.closeMessage()
	e.closeFunctionCalls()
}

// hasToolCalls reports whether at least one function_call item was emitted.
func (e *responsesStreamEmitter) hasToolCalls() bool {
	return e.sawToolCall
}

// finish closes all open items and emits the terminal lifecycle event
// (response.completed, or response.incomplete when generation was truncated).
func (e *responsesStreamEmitter) finish(usage protocol.UsageInfo) {
	finishReason := effectiveFinishReason(e.finishReason, e.hasToolCalls(), usage, e.pr.RequestedMaxTokens)
	if len(e.output) == 0 && !e.messageOpen && !e.reasoningOpen && len(e.fnOrder) == 0 {
		e.ensureMessageOpen()
	}
	e.closeOpenItems()

	reasoningTokens := resolveReasoningTokens(usage, e.reasoningBuf.String())
	u := buildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens, uint64(usage.CachedTokens))

	status := "completed"
	eventType := "response.completed"
	incomplete := buildResponsesIncompleteDetails(finishReason)
	if incomplete != nil {
		status = "incomplete"
		eventType = "response.incomplete"
	}
	snap := responsesSnapshot(
		e.responseID, e.createdAt, e.model, status, e.output, &u, incomplete,
		e.pr.Traits)
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
