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

type genericEndpointStreamEmitter interface {
	start()
	handleChunk(string)
	finish(protocol.UsageInfo)
	emitError(string, string)
}

func (s *Server) handleGenericEndpointStreamingResponseWithError(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}
	writeSSEResponseHeader(w, pr.RequestID)

	// The emitter flushes after every event; defer those flushes so a burst of
	// already-queued provider chunks reaches the wire in one Flush. Every
	// return path performs the owed flush.
	deferred := newDeferredFlusher(flusher)
	defer deferred.flushNow()

	emitter := newGenericEndpointStreamEmitter(w, deferred, pr)
	emitter.start()
	for _, chunk := range firstChunks {
		if chunk != "" {
			emitter.handleChunk(sanitizeStreamCacheDetails(chunk))
		}
	}
	if initialError != nil {
		s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
		s.noteInferenceError(pr.ProviderID, pr, initialError.StatusCode, initialError.Error, initialError.ErrorReason, initialError.TerminalCause, initialError.CoordinatorCause)
		s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, *initialError))
		emitter.emitError("provider_error", clientSafeInferenceErrorMessage(*initialError))
		return
	}
	// The preamble (start event + dispatch-time chunks) goes on the wire
	// before blocking on the provider.
	deferred.flushNow()

	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	// emitProviderError settles and reports an in-band provider error.
	emitProviderError := func(errMsg protocol.InferenceErrorMessage) {
		s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
		s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
		s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, errMsg))
		emitter.emitError("provider_error", clientSafeInferenceErrorMessage(errMsg))
	}

	// finishStream runs once ChunkCh is observed closed — on the blocking
	// receive or while draining already-queued chunks (after those were
	// flushed). A provider error is delivered on ErrorCh just before the
	// channels close, so it is checked first: a close must never turn a real
	// provider error into "incomplete".
	finishStream := func() {
		select {
		case errMsg, ok := <-pr.ErrorCh:
			if ok && errMsg.Error != "" {
				emitProviderError(errMsg)
				return
			}
		default:
		}
		var usage protocol.UsageInfo
		select {
		case complete, completeOK := <-pr.CompleteCh:
			if !completeOK {
				s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
				s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderIncompleteOutcome(pr))
				emitter.emitError("provider_error", "provider ended without completion")
				return
			}
			usage = complete
		case <-time.After(2 * time.Second):
			s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
			s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderIncompleteOutcome(pr))
			emitter.emitError("provider_error", "provider ended without completion")
			return
		case <-r.Context().Done():
			profileClientGone(pr, phaseAfterCommit)
			return
		}
		s.noteInferenceSuccess(pr)
		emitter.finish(usage)
	}

	relayChunk := func(chunk registry.ProviderChunk) {
		emitter.handleChunk(sanitizeStreamCacheDetails(chunk.Data))
		resetIdleTimer(timer, inferenceTimeout)
	}

	for {
		select {
		case providerChunk, ok := <-pr.ChunkCh:
			if !ok {
				finishStream()
				return
			}
			relayChunk(providerChunk)
			// Fold in whatever the provider already queued behind this chunk
			// (never waiting for more), then flush the batch once. A close
			// observed mid-drain is handled exactly like the blocking-receive
			// close — after the drained chunks are on the wire.
			closed := drainQueuedChunks(pr.ChunkCh, maxCoalescedChunks-1, relayChunk)
			deferred.flushNow()
			if closed {
				finishStream()
				return
			}

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			// Forward chunks queued ahead of the error before the terminal
			// event (see the chat relay for the rationale).
			drainQueuedChunks(pr.ChunkCh, cap(pr.ChunkCh), relayChunk)
			deferred.flushNow()
			emitProviderError(errMsg)
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitStreamTimeoutOutcome(pr))
			emitter.emitError("timeout", "request timed out")
			return

		case <-r.Context().Done():
			profileClientGone(pr, phaseAfterCommit)
			return
		}
	}
}

func newGenericEndpointStreamEmitter(
	w http.ResponseWriter,
	flusher http.Flusher,
	pr *registry.PendingRequest,
) genericEndpointStreamEmitter {
	if pr.ConsumerEndpoint == messagesEndpoint {
		return newMessagesStreamEmitter(w, flusher, pr)
	}
	return &completionsStreamEmitter{w: w, flusher: flusher, pr: pr, stamps: newRelayStamps(pr.Profile.Parent(), pr.Accounting.Parent())}
}

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
		}, true)
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
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
	e.stamps.done()
}

func (e *completionsStreamEmitter) emitError(kind, message string) {
	if e.emit(map[string]any{"error": map[string]any{"type": kind, "message": message}}) {
		e.stamps.accounting.Egress(true, false, "error")
	}
}

func (e *completionsStreamEmitter) emit(value any, content ...bool) bool {
	encoded, err := json.Marshal(value)
	if err != nil {
		return false
	}
	n, werr := fmt.Fprintf(e.w, "data: %s\n\n", encoded)
	accepted := werr == nil && n == len(encoded)+8
	if len(content) > 0 && content[0] && accepted {
		e.stamps.content()
	}
	if n != len(encoded)+8 {
		e.stamps.writeErr()
	}
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
	return accepted
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
		stamps:    newRelayStamps(pr.Profile.Parent(), pr.Accounting.Parent()),
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
	if e.emit("error", map[string]any{
		"error": map[string]any{"type": kind, "message": message},
	}) {
		e.stamps.accounting.Egress(true, false, "error")
	}
}

func (e *messagesStreamEmitter) emit(eventType string, fields map[string]any) bool {
	fields["type"] = eventType
	encoded, err := json.Marshal(fields)
	if err != nil {
		return false
	}
	n, werr := fmt.Fprintf(e.w, "event: %s\ndata: %s\n\n", eventType, encoded)
	accepted := werr == nil && n == len(eventType)+len(encoded)+16
	if !e.stamps.contentWritten && accepted && accountingValueHasContent(fields, 0) {
		e.stamps.content()
	}
	if n != len(eventType)+len(encoded)+16 {
		e.stamps.writeErr()
	}
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
	return accepted
}
