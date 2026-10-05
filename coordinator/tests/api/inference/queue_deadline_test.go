package inference_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestQueuedRequestExpiresAsQueueDeadlineLive drives the REAL HTTP path: the
// single slot is saturated, the request queues, nothing drains it, and the
// 400ms first-content deadline fires inside the queue wait.
func TestOwnerPreferredQueuedRequestExpiresAsQueueDeadlineLive(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const model = "queue-deadline-live-model"
	_, st, reg, ts := queuedFleetHarness(t, ctx, TestServerConfig{FirstContentDeadlineBase: 400 * time.Millisecond}, model)

	start := time.Now()
	res := chatRequestWithID(ctx, ts.URL, model, "queue-deadline-live", "prefer")
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
	if !strings.Contains(res.body, "rate_limit_exceeded") || !strings.Contains(res.body, retry.QueueDeadlineError) {
		t.Fatalf("body is not the queue-deadline rejection: %s", res.body)
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
	if rec.ReasonCode !=
		retry.QueueDeadlineReason {
		t.Fatalf("rejection ReasonCode = %q, want %q", rec.ReasonCode, retry.QueueDeadlineReason)
	}
	if rec.HTTPStatus != http.StatusTooManyRequests || rec.RetryAfterMs <= 0 {
		t.Fatalf("rejection record = status %d retry_after_ms %d, want 429 with a positive Retry-After", rec.HTTPStatus, rec.RetryAfterMs)
	}
	if rec.ResolvedModel != model {
		t.Fatalf("rejection ResolvedModel = %q, want %q", rec.ResolvedModel, model)
	}
}

// TestResolveDominantExhaustedStatus_QueueDeadline pins the classification at
// the unit level: the queue-wait synthetic 504 reclassifies to a 429 with
// reason queue_deadline; the dispatched-provider synthetic 504 keeps
// first_chunk_timeout; a sticky genuine provider fault is never overridden.
func TestResolveDominantExhaustedStatus_QueueDeadline(t *testing.T) {
	newState := func() *retry.TerminalEvidence {
		return &retry.TerminalEvidence{}
	}

	d := newState()
	current := retry.CoordinatorFailure(retry.QueueDeadlineError,

		http.StatusGatewayTimeout)
	failure, sticky := d.Select(retry.NewTerminalFailure(current.Message, backend.Slot{}), false)
	code, reason, reclassified, dominance := retry.ResolveTerminal(failure, sticky, retry.TerminalPolicy{})
	if code != http.StatusTooManyRequests || reason !=
		retry.QueueDeadlineReason ||
		!reclassified || dominance !=
		retry.Undecided {
		t.Fatalf("queue deadline = (%d, %q, %v, %d), want (429, queue_deadline, true, undecided)", code, reason, reclassified, dominance)
	}

	d = newState()
	current = retry.CoordinatorFailure("timeout waiting for first response", http.StatusGatewayTimeout)
	failure, sticky = d.Select(retry.NewTerminalFailure(current.Message, backend.Slot{}), false)
	code, reason, reclassified, _ = retry.ResolveTerminal(failure, sticky, retry.TerminalPolicy{})
	if code != http.StatusTooManyRequests || reason != "first_chunk_timeout" || !reclassified {
		t.Fatalf("dispatched timeout = (%d, %q, %v), want (429, first_chunk_timeout, true)", code, reason, reclassified)
	}

	// A sticky genuine fault from an earlier attempt outranks the queue's
	// terminal: its own text, its own status.
	d = newState()
	d.Capture(protocol.InferenceErrorMessage{Error: "boom", StatusCode: http.StatusBadGateway}, 0, 0, backend.Slot{})
	current = retry.CoordinatorFailure(retry.QueueDeadlineError,

		http.StatusGatewayTimeout)
	failure, sticky = d.Select(retry.NewTerminalFailure(current.Message, backend.Slot{}), false)
	code, reason, reclassified, dominance = retry.ResolveTerminal(failure, sticky, retry.TerminalPolicy{})
	if !sticky || code != http.StatusBadGateway || reason != "dispatch_exhausted" || reclassified || dominance !=
		retry.GenuineFault {
		t.Fatalf("sticky fault = (%d, %q, %v, %d), want (502, dispatch_exhausted, false, genuine fault)", code, reason, reclassified, dominance)
	}
}
