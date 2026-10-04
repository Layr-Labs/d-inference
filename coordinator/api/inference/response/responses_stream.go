package response

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	responsepolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/responsepolicy"
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

// responsesStreamEmitter translates provider chat.completion.chunk deltas into
// incremental OpenAI Responses API SSE events. Every event carries an `event:`
// line and a monotonically increasing sequence_number, matching the official
// Responses streaming wire format.
type ResponsesStreamEmitter struct {
	w       http.ResponseWriter
	flusher http.Flusher
	pr      *registry.PendingRequest
	stamps  *observation.RelayStamps

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

func NewResponsesStreamEmitter(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest, responseID string, createdAt int64) *ResponsesStreamEmitter {
	return &ResponsesStreamEmitter{
		w:               w,
		flusher:         flusher,
		pr:              pr,
		stamps:          observation.NewRelayStamps(pr.Profile.Parent()),
		responseID:      responseID,
		createdAt:       createdAt,
		model:           ConsumerModel(pr),
		activeFnByIndex: map[int]*streamFnState{},
	}
}

// start emits response.created and response.in_progress.
func (e *ResponsesStreamEmitter) Start() {
	e.emit("response.created", map[string]any{
		"response": responsepolicy.ResponsesSnapshot(e.responseID, e.createdAt, e.model, "in_progress", nil, nil, nil, e.pr.Traits),
	})
	e.emit("response.in_progress", map[string]any{
		"response": responsepolicy.ResponsesSnapshot(e.responseID, e.createdAt, e.model, "in_progress", nil, nil, nil, e.pr.Traits),
	})
}

// handleChunk translates one provider SSE chunk into incremental events.
func (e *ResponsesStreamEmitter) HandleChunk(chunk string) {
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

func (e *ResponsesStreamEmitter) appendReasoning(delta string) {
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

func (e *ResponsesStreamEmitter) closeReasoning() {
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

func (e *ResponsesStreamEmitter) appendContent(delta string) {
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

func (e *ResponsesStreamEmitter) ensureMessageOpen() {
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

func (e *ResponsesStreamEmitter) closeMessage() {
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
func (e *ResponsesStreamEmitter) appendToolCall(tc streamToolCallDelta) {
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
func (e *ResponsesStreamEmitter) closeFunctionCalls() {
	for _, state := range e.fnOrder {
		e.closeFunctionCall(state)
	}
	e.fnOrder = nil
	clear(e.activeFnByIndex)
}

func (e *ResponsesStreamEmitter) closeFunctionCall(st *streamFnState) {
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

func (e *ResponsesStreamEmitter) closeOpenItems() {
	e.closeReasoning()
	e.closeMessage()
	e.closeFunctionCalls()
}

// hasToolCalls reports whether at least one function_call item was emitted.
func (e *ResponsesStreamEmitter) hasToolCalls() bool {
	return e.sawToolCall
}

// finish closes all open items and emits the terminal lifecycle event
// (response.completed, or response.incomplete when generation was truncated).
func (e *ResponsesStreamEmitter) Finish(usage protocol.UsageInfo) {
	finishReason := responsepolicy.EffectiveFinishReason(e.finishReason, e.hasToolCalls(), usage, e.pr.RequestedMaxTokens)
	if len(e.output) == 0 && !e.messageOpen && !e.reasoningOpen && len(e.fnOrder) == 0 {
		e.ensureMessageOpen()
	}
	e.closeOpenItems()

	reasoningTokens := responsepolicy.ResolveReasoningTokens(usage, e.reasoningBuf.String())
	u := responsepolicy.BuildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens, uint64(usage.CachedTokens))

	status := "completed"
	eventType := "response.completed"
	incomplete := buildResponsesIncompleteDetails(finishReason)
	if incomplete != nil {
		status = "incomplete"
		eventType = "response.incomplete"
	}
	snap := responsepolicy.ResponsesSnapshot(
		e.responseID, e.createdAt, e.model, status, e.output, &u, incomplete,
		e.pr.Traits)
	if e.pr.SESignature != "" {
		snap["se_signature"] = e.pr.SESignature
		snap["response_hash"] = e.pr.ResponseHash
	}
	e.emit(eventType, map[string]any{"response": snap})
	e.stamps.Done()
}

// emitError emits a Responses-API error event.
func (e *ResponsesStreamEmitter) EmitError(errType, message string) {
	e.emit("error", map[string]any{
		"error": map[string]any{
			"type":    errType,
			"code":    errType,
			"message": message,
			"param":   nil,
		},
	})
}
