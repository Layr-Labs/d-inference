package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// SSE prefill keepalives.
//
// On a long-prompt request the coordinator commits HTTP 200 + the first byte
// only AFTER the provider's first content chunk arrives (deferred commit), which
// keeps clean status codes and lets failover/retry stay invisible. But a long
// prefill (time-to-first-token up to ~100s on big prompts) means dead air on the
// wire, and OpenRouter's fetch timeout then fires, cancels the request, and fails
// us over — counted against our uptime.
//
// prefillKeepaliver bridges that gap: once a request has been DISPATCHED to a
// provider and we are waiting for its first chunk, it commits HTTP 200 and emits
// periodic ": keepalive" SSE comments so the consumer connection stays alive. It
// only ever fires after one full interval, so a request that produces content
// quickly never commits early and retains the full deferred-commit / invisible-
// failover behavior — only genuine long prefills (the ones that were timing out)
// commit early. It is enabled by EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL
// (0 = off, the default).
//
// Tradeoff once a keepalive has committed HTTP 200: the status code is frozen at
// 200, so a subsequent failure can no longer be returned as a clean 4xx/5xx — it
// is surfaced in-band as an SSE error event, and failover to another provider
// (if it succeeds) is still transparent to the consumer. Pairing keepalives with
// the smart admission gate keeps the early-commit set to requests we expect to
// serve. Per-response provider attestation / X-Timing headers, computed at first
// chunk, are omitted on keepalive-committed responses (they cannot be set after
// the header is flushed).
//
// Concurrency: the keepalive goroutine and the request goroutine that finally
// writes the response are mutually excluded by the keepaliver's mutex. takeOver
// stops the goroutine and hands sole ownership of the ResponseWriter back to the
// caller (reporting whether the SSE 200 was already written), so there is exactly
// one writer at any time.
type prefillKeepaliver struct {
	w        http.ResponseWriter
	flusher  http.Flusher
	interval time.Duration
	jobID    string

	mu        sync.Mutex
	committed bool // SSE headers + HTTP 200 have been written by a keepalive
	done      bool // taken over / stopped: the goroutine must not write again
	stopCh    chan struct{}
}

// newPrefillKeepaliver returns a keepaliver for the request, or nil when prefill
// keepalives are disabled (interval <= 0) or the writer cannot stream/flush.
func (s *Server) newPrefillKeepaliver(w http.ResponseWriter, jobID string) *prefillKeepaliver {
	if s == nil || s.prefillKeepaliveInterval <= 0 {
		return nil
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		return nil
	}
	return &prefillKeepaliver{
		w:        w,
		flusher:  fl,
		interval: s.prefillKeepaliveInterval,
		jobID:    jobID,
		stopCh:   make(chan struct{}),
	}
}

// start launches the keepalive goroutine. The first keepalive fires one interval
// from now. ctx cancellation (client disconnect) stops it. nil-safe.
func (k *prefillKeepaliver) start(ctx context.Context) {
	if k == nil {
		return
	}
	go func() {
		t := time.NewTicker(k.interval)
		defer t.Stop()
		for {
			select {
			case <-k.stopCh:
				return
			case <-ctx.Done():
				return
			case <-t.C:
				if !k.writeKeepalive() {
					return
				}
			}
		}
	}()
}

// writeKeepalive commits the SSE 200 header (once) and writes a ": keepalive"
// comment. Returns false when the keepaliver has been taken over or stopped (the
// goroutine then exits).
func (k *prefillKeepaliver) writeKeepalive() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.done {
		return false
	}
	if !k.committed {
		writeSSEResponseHeader(k.w, k.jobID)
		k.committed = true
	}
	// SSE comment line: ignored by clients, resets idle/fetch timeouts.
	fmt.Fprint(k.w, ": keepalive\n\n")
	k.flusher.Flush()
	return true
}

// takeOver stops the keepalive goroutine and reports whether a keepalive already
// committed the SSE 200 header. After it returns, no keepalive will write again,
// so the caller owns all further writes to the ResponseWriter. Idempotent and
// nil-safe (a nil keepaliver reports false — keepalives were disabled).
func (k *prefillKeepaliver) takeOver() (headerWritten bool) {
	if k == nil {
		return false
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if !k.done {
		k.done = true
		close(k.stopCh)
	}
	return k.committed
}

// writeSSEResponseHeader writes the standard SSE response headers and commits
// HTTP 200. Shared by the keepaliver and the streaming response writer so the
// committed header is identical regardless of which one writes it first.
func writeSSEResponseHeader(w http.ResponseWriter, jobID string) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// X-Request-ID is set by the logging middleware to the trace ID. The internal
	// job UUID can change across retries, so surface it under its own header for
	// callers correlating to provider-side logs.
	if jobID != "" {
		w.Header().Set("X-Inference-Job-ID", jobID)
	}
	w.WriteHeader(http.StatusOK)
}

// writeSSEErrorEvent emits a terminal error to an already-committed SSE stream as
// a data event followed by [DONE]. Used when a keepalive has already committed
// HTTP 200 and the request then fails, so a normal status-coded JSON error can no
// longer be sent.
func writeSSEErrorEvent(w http.ResponseWriter, resp any) {
	b, err := json.Marshal(resp)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", b)
	fmt.Fprint(w, "data: [DONE]\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// writeResponsesSSEErrorEvent emits an OpenAI Responses-API-shaped terminal error
// event (event: error, no [DONE]) to an already-committed SSE stream. Used when a
// prefill keepalive has committed HTTP 200 for a /v1/responses request and it then
// fails: the chat-completions-shaped writeSSEErrorEvent would not parse for strict
// Responses clients. Mirrors responsesStreamEmitter.emitError / emit in
// responses_stream.go.
func writeResponsesSSEErrorEvent(w http.ResponseWriter, errType, message string) {
	payload := map[string]any{
		"type":            "error",
		"sequence_number": 0,
		"error": map[string]any{
			"type":    errType,
			"code":    errType,
			"message": message,
			"param":   nil,
		},
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "event: error\ndata: %s\n\n", b)
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}
