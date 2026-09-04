package api

// queue_deadline: a request whose request-absolute first-content clock
// expires while it is still waiting in the coordinator queue was reported as
// first_chunk_timeout — indistinguishable in the rejection ledger and route
// rows from a dispatched provider that went silent. It now carries its own
// reason code (and a position-aware Retry-After), with the same retryable 429
// body. Prod value is bounded: with QUEUE_MAX_WAIT=6s the per-waiter timer
// usually wins (queue_timeout), so the reclassification matters when routing
// burned > 3 s before enqueue — the expected acceptance number is the
// request_rejections reason_code split (queue_deadline vs first_chunk_timeout).

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestQueuedRequestExpiresAsQueueDeadlineLive drives the REAL HTTP path: the
// single slot is saturated, the request queues, nothing drains it, and the
// 400ms first-content deadline fires inside the queue wait.
func TestQueuedRequestExpiresAsQueueDeadlineLive(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const model = "queue-deadline-live-model"
	_, st, reg, ts := queuedFleetHarness(t, ctx, ServerConfig{FirstContentDeadlineBase: 400 * time.Millisecond}, model)

	start := time.Now()
	res := chatRequestWithID(ctx, ts.URL, model, "")
	elapsed := time.Since(start)
	if res.err != nil {
		t.Fatalf("chat request: %v", res.err)
	}
	if res.status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body=%s", res.status, res.body)
	}
	if res.retryAfter == "" {
		t.Fatal("queue_deadline 429 missing Retry-After")
	}
	// Client-visible shape is unchanged: the retryable rate_limit_exceeded
	// body the exhausted ladder always wrote for a synthetic timeout.
	if !strings.Contains(res.body, "rate_limit_exceeded") || !strings.Contains(res.body, "timeout waiting for first response") {
		t.Fatalf("body is not the retryable timeout rejection: %s", res.body)
	}
	if elapsed > 5*time.Second {
		t.Fatalf("request resolved after %v, want the ~400ms first-content deadline, not the queue max wait", elapsed)
	}
	if depth := reg.Queue().QueueSize(model); depth != 0 {
		t.Fatalf("queue depth = %d after the deadline terminal, want 0", depth)
	}

	// The rejection ledger (written asynchronously) must carry the queue's own
	// reason, never first_chunk_timeout.
	var rec *store.RejectionRecord
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && rec == nil {
		for _, r := range st.RejectionRecordsSince(time.Time{}) {
			if r.Stage == "dispatch" {
				r := r
				rec = &r
				break
			}
		}
		if rec == nil {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if rec == nil {
		t.Fatalf("no dispatch-stage rejection recorded; records=%+v", st.RejectionRecordsSince(time.Time{}))
	}
	if rec.ReasonCode != rejectionReasonQueueDeadline {
		t.Fatalf("rejection ReasonCode = %q, want %q", rec.ReasonCode, rejectionReasonQueueDeadline)
	}
	if rec.HTTPStatus != http.StatusTooManyRequests || rec.RetryAfterMs <= 0 {
		t.Fatalf("rejection record = status %d retry_after_ms %d, want 429 with a positive Retry-After", rec.HTTPStatus, rec.RetryAfterMs)
	}
	if rec.ResolvedModel != model {
		t.Fatalf("rejection ResolvedModel = %q, want %q", rec.ResolvedModel, model)
	}
	// The route row classifies the queue's terminal as capacity, not as a
	// provider fault (no provider was ever involved).
	routes := routeRecordsFor(t, st, model, 1)
	if got := routes[0].ErrorReason; got != errorReasonCapacityTimeout {
		t.Fatalf("route error_reason = %q, want %q (queue_deadline counts as capacity)", got, errorReasonCapacityTimeout)
	}
}

// TestResolveDominantExhaustedStatus_QueueDeadline pins the classification at
// the unit level: the queue-wait synthetic 504 reclassifies to a 429 with
// reason queue_deadline; the dispatched-provider synthetic 504 keeps
// first_chunk_timeout; a typed provider 504 stays 504; a sticky genuine
// provider fault is never overridden.
func TestResolveDominantExhaustedStatus_QueueDeadline(t *testing.T) {
	srv, _ := testServer(t)
	newState := func() *dispatchState {
		return &dispatchState{s: srv, model: "m", excludeProviders: map[string]struct{}{}}
	}

	d := newState()
	d.queueExpired = true
	d.queueExitPosition = 7
	d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
	failure, sticky := d.terminalFailureForExhaustion()
	code, reason, reclassified, dominance := d.resolveDominantExhaustedStatus(failure, sticky)
	if code != http.StatusTooManyRequests || reason != rejectionReasonQueueDeadline || !reclassified || dominance != exhaustedUndecided {
		t.Fatalf("queue deadline = (%d, %q, %v, %d), want (429, queue_deadline, true, undecided)", code, reason, reclassified, dominance)
	}

	d = newState()
	d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
	failure, sticky = d.terminalFailureForExhaustion()
	code, reason, reclassified, _ = d.resolveDominantExhaustedStatus(failure, sticky)
	if code != http.StatusTooManyRequests || reason != "first_chunk_timeout" || !reclassified {
		t.Fatalf("dispatched timeout = (%d, %q, %v), want (429, first_chunk_timeout, true)", code, reason, reclassified)
	}

	// A typed provider 504 is a real provider terminal even when the queue
	// flag is (impossibly) set.
	if code, reason, reclassified := classifyExhaustedStatus(http.StatusGatewayTimeout, terminalCauseSafetyDeadline, true); code != http.StatusGatewayTimeout || reason != "dispatch_exhausted" || reclassified {
		t.Fatalf("typed 504 = (%d, %q, %v), want (504, dispatch_exhausted, false)", code, reason, reclassified)
	}

	// A sticky genuine fault from an earlier attempt outranks the queue's
	// terminal: its own text, its own status.
	d = newState()
	fault := dispatchTerminalFailure{errText: "boom", statusCode: http.StatusBadGateway}
	d.genuineFault = &fault
	d.queueExpired = true
	d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
	failure, sticky = d.terminalFailureForExhaustion()
	code, reason, reclassified, dominance = d.resolveDominantExhaustedStatus(failure, sticky)
	if !sticky || code != http.StatusBadGateway || reason != "dispatch_exhausted" || reclassified || dominance != exhaustedGenuineFault {
		t.Fatalf("sticky fault = (%d, %q, %v, %d), want (502, dispatch_exhausted, false, genuine fault)", code, reason, reclassified, dominance)
	}

	// Route-outcome vocabulary: queue_deadline is a capacity terminal.
	if got := inferenceErrorReason("", "timeout", rejectionReasonQueueDeadline, http.StatusGatewayTimeout, ""); got != errorReasonCapacityTimeout {
		t.Fatalf("route error reason for queue_deadline = %q, want %q", got, errorReasonCapacityTimeout)
	}
}
