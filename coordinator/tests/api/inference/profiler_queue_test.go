package inference_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestQueuedAttemptWriteFailureClosesNotDispatched drives the real queue path:
// the request queues, the drain hands over a provider whose socket is gone, and
// the frame write fails after the pending request was already assigned. The
// placeholder must close as not_dispatched with the write failure's class.
func TestQueuedAttemptWriteFailureClosesNotDispatched(t *testing.T) {
	s := newTestServerForDispatch(t)
	s.registry.SetQueue(registry.NewRequestQueue(4, 5*time.Second))
	const model = "queue-write-failure"
	rp := observedTestProfile(t, s, time.Now(), "coord-queue-write")
	request := queuePrimaryRequest(model, rp, httptest.NewRequest(http.MethodPost, "/v1/completions", nil), 10*time.Second)
	primary := s.NewPrimary(inference.PrimaryResources{})
	outcome := make(chan inference.PrimaryResult, 1)
	go func() { outcome <- primary.Run(request) }()
	// Register the provider only once the request is queued, or attempt 0
	// would reserve it directly and never take the queue path.
	waitForAdaptiveCondition(t, 3*time.Second, func() bool {
		return s.registry.Queue().QueueSize(model) >= 1
	})
	p := makeRoutableProvider(t, s.registry, "queue-write-failure-provider", model) // nil Conn: the frame write fails
	s.registry.DrainQueuedRequestsForModel(model)

	var result inference.PrimaryResult
	select {
	case result = <-outcome:
		if got := result.Outcome; got != attempt.Retry {
			t.Fatalf("dispatchPrimary=%v, want retry after the write failure", got)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("dispatchPrimary did not return")
	}
	if result.History.Failure.Message.Error != "failed to send request to provider" {
		t.Fatalf("lastErr=%q, want the write failure", result.History.Failure.Message.Error)
	}
	ap := queuedPlaceholder(t, rp)
	if ap.Finalized() || !ap.TerminalRecorded() {
		t.Fatalf("failure site must close only the terminal half: finalized=%v terminal=%v", ap.Finalized(), ap.TerminalRecorded())
	}
	ap.CompleteHandler() // what finalizeProfile does once the dispatch loop returns
	if !ap.Finalized() {
		t.Fatal("attempt must finalize once the handler half lands")
	}
	rec := awaitPersistedProfile(t, s, ap)
	if rec.ProviderOutcome != "not_dispatched" || rec.FinalStatus != "error" || rec.ErrorReason != "provider_error" {
		t.Fatalf("outcome = %q/%q/%q, want not_dispatched/error/provider_error", rec.ProviderOutcome, rec.FinalStatus, rec.ErrorReason)
	}
	if rec.ProviderID != p.ID || rec.DequeuedUS == nil || rec.WriteSubmittedUS == nil || rec.WriteDoneUS != nil {
		t.Fatalf("row must show the queue handover and a submitted-but-never-done write: provider=%q dequeued=%v submitted=%v done=%v",
			rec.ProviderID, rec.DequeuedUS, rec.WriteSubmittedUS, rec.WriteDoneUS)
	}
}

// TestQueuedAttemptExitsCarryRouteOutcome drives each exit of the queue wait
// through the primary dispatcher and checks the placeholder's route vocabulary.
// queue_full has no route outcome (recorded only after a successful enqueue), so
// it carries the rejection vocabulary instead.
func TestQueuedAttemptExitsCarryRouteOutcome(t *testing.T) {
	const model = "queue-exit-outcome"
	failQueued := func(reason error) func(*testing.T, *serverFixture, context.CancelFunc) {
		return func(t *testing.T, s *serverFixture, _ context.CancelFunc) {
			req := s.registry.Queue().PopNextFresh(model)
			if req == nil {
				t.Fatal("no queued request to fail")
			}
			req.FailureReason = reason // nil -> ErrQueueTimeout
			req.ResponseCh <- nil
		}
	}
	cases := []struct {
		name        string
		maxSize     int
		deadline    time.Duration
		trigger     func(*testing.T, *serverFixture, context.CancelFunc) // nil: the exit fires on its own
		wantOutcome attempt.Outcome
		wantStatus  string
		wantReason  string
	}{
		{"queue_full", 0, 10 * time.Second, nil, attempt.ResponseWritten, "rejected", "queue_full"},
		{"client_gone", 4, 10 * time.Second, func(_ *testing.T, _ *serverFixture, cancel context.CancelFunc) { cancel() }, attempt.ClientGone, "cancelled", "client_gone"},
		// The queue-wait first-content expiry is the queue's own terminal
		// (queue_deadline), kept distinct from a dispatched provider's silence.
		{"queue_deadline", 4, 200 * time.Millisecond, nil, attempt.FailFast, "timeout", retry.QueueDeadlineReason},
		{"ttft_too_slow", 4, 10 * time.Second, failQueued(registry.ErrQueueTTFTTooSlow), attempt.ResponseWritten, "error", "ttft_too_slow"},
		{"model_capability_unsupported", 4, 10 * time.Second, failQueued(registry.ErrQueueToolConstraintUnavailable), attempt.ResponseWritten, "error", "model_capability_unsupported"},
		{"queue_timeout", 4, 10 * time.Second, failQueued(nil), attempt.ResponseWritten, "timeout", "queue_timeout"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServerForDispatch(t)
			s.registry.SetQueue(registry.NewRequestQueue(tc.maxSize, 5*time.Second))
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			rp := observedTestProfile(t, s, time.Now(), "coord-"+tc.name)
			request := queuePrimaryRequest(model, rp, httptest.NewRequest(http.MethodPost, "/v1/completions", nil).WithContext(ctx), tc.deadline)
			primary := s.NewPrimary(inference.PrimaryResources{})
			outcome := make(chan inference.PrimaryResult, 1)
			go func() { outcome <- primary.Run(request) }()
			if tc.trigger != nil {
				waitForAdaptiveCondition(t, 3*time.Second, func() bool {
					return s.registry.Queue().QueueSize(model) >= 1
				})
				tc.trigger(t, s, cancel)
			}
			select {
			case result := <-outcome:
				if got := result.Outcome; got != tc.wantOutcome {
					t.Fatalf("dispatchPrimary=%v, want %v", got, tc.wantOutcome)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("dispatchPrimary did not return")
			}
			ap := queuedPlaceholder(t, rp)
			if !ap.TerminalRecorded() || ap.Finalized() {
				t.Fatalf("queue exit must close only the terminal half: terminal=%v finalized=%v", ap.TerminalRecorded(), ap.Finalized())
			}
			ap.CompleteHandler()
			rec := awaitPersistedProfile(t, s, ap)
			if rec.FinalStatus != tc.wantStatus || rec.ErrorReason != tc.wantReason || rec.ProviderOutcome != "not_dispatched" {
				t.Fatalf("row = %q/%q/%q, want %s/%s/not_dispatched", rec.FinalStatus, rec.ErrorReason, rec.ProviderOutcome, tc.wantStatus, tc.wantReason)
			}
		})
	}
}
