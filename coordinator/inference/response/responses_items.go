package response

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// handleChunk translates one provider SSE chunk into incremental events.
func (e *responsesStreamEmitter) Chunk(chunk string) {
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

func (e *responsesStreamEmitter) closeOpenItems() {
	e.closeReasoning()
	e.closeMessage()
	e.closeFunctionCalls()
}

// finish closes all open items and emits the terminal lifecycle event
// (response.completed, or response.incomplete when generation was truncated).
func (e *responsesStreamEmitter) Finish(usage protocol.UsageInfo) {
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
	e.stamps.done()
}

// emitError emits a Responses-API error event.
func (e *responsesStreamEmitter) Error(errType, message string) {
	e.emit("error", map[string]any{
		"error": map[string]any{
			"type":    errType,
			"code":    errType,
			"message": message,
			"param":   nil,
		},
	})
}
