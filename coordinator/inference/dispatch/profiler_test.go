package dispatch

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/registry"
	profiling "github.com/eigeninference/d-inference/coordinator/telemetry/profiler"
)

func TestTimingJSONAdditiveKeysAndClamp(t *testing.T) {
	srv := newTestController(t)
	rp := registry.NewRequestProfile(time.Now().Add(-time.Second), "c", nil, 0)
	rp.PreflightUS = 300
	rp.Stamp(&rp.HandlerEntryUS)
	ap := rp.NewAttempt("a", 0, "")
	ap.AttemptStartUS.Store(1000)
	ap.ReserveDoneUS.Store(1500)
	ap.WriteSubmittedUS.Store(2000)
	ap.WriteDequeuedUS.Store(2100)
	ap.WriteDoneUS.Store(2400)
	ap.AcceptedUS.Store(3400)
	pr := &registry.PendingRequest{Profile: ap}
	d := &execution{s: srv, profile: rp}
	tj := types.RequestTimingDetails{ParseUs: -5, ProviderUs: 10}
	d.applyProfileTiming(&tj, pr)
	if tj.ParseUs != 0 || !tj.TimingAnomaly {
		t.Fatal("negative legacy segment must clamp to 0 and flag anomaly")
	}
	if tj.RouteReserveUs != 500 || tj.WriterUs != 100 || tj.SocketUs != 300 || tj.ProviderAckUs != 1000 || tj.PreflightUs != 300 {
		t.Fatalf("additive keys wrong: %+v", tj)
	}
	b, _ := json.Marshal(tj)
	for _, key := range []string{"parse_us", "provider_us", "route_reserve_us", "writer_us", "socket_us", "provider_ack_us", "preflight_us"} {
		if !json.Valid(b) || !containsKey(b, key) {
			t.Fatalf("X-Timing missing %s: %s", key, b)
		}
	}
}

func TestCloseUndispatchedAttemptCoversWriteFailure(t *testing.T) {
	var finalized int
	rp := registry.NewRequestProfile(time.Now(), "c", func(*registry.RequestProfile, *registry.AttemptProfile) { finalized++ }, 0)
	ap := rp.NewAttempt("a", 0, "")
	ap.Mark(registry.StampWriteSubmitted) // submitted, but the write failed: WriteDone never set
	closeUndispatchedAttempt(ap, "failed to send request to provider", 502)
	if finalized != 0 {
		t.Fatalf("closing an undispatched attempt must only complete the terminal half (the record is built after the handler returns), finalized=%d", finalized)
	}
	ap.CompleteHandler() // what finalizeProfile does once the dispatch loop returns
	if finalized != 1 {
		t.Fatalf("write-failed attempt must finalize once the handler half lands, finalized=%d", finalized)
	}
	fs, _, _, po, _ := ap.Outcome()
	if fs != "error" || po != "not_dispatched" {
		t.Fatalf("outcome %q/%q", fs, po)
	}
	ok := rp.NewAttempt("b", 1, "")
	ok.Mark(registry.StampWriteDone)
	closeUndispatchedAttempt(ok, "x", 500)
	if ok.Finalized() {
		t.Fatal("a dispatched attempt must be left to its provider terminal")
	}
}

// TestQueuedAttemptWriteFailureClosesNotDispatched drives the REAL queue
// path: the request queues, the drain hands over a provider whose socket is
// gone, and the frame write fails after d.pr was already assigned. The
// placeholder attempt must close as not_dispatched with the write failure's
// class — not finalize with an empty provider_outcome because d.pr pointed at
// it (the old defer keyed on d.pr == queuePR, which is set BEFORE the write).
// queueDispatchState builds the execution the queue-path tests drive
// through the real dispatchPrimary: with no routable provider registered,
// attempt 0 finds none and the request takes the queue path.
func queueDispatchState(s *Controller, model string, rp *registry.RequestProfile, r *http.Request, deadline time.Duration) *execution {
	return &execution{
		s:                      s,
		w:                      httptest.NewRecorder(),
		r:                      r,
		model:                  model,
		publicModel:            model,
		rawBody:                []byte(`{"model":"` + model + `","messages":[]}`),
		consumerEndpoint:       response.CompletionsEndpoint,
		timing:                 &registry.RequestTiming{ReceivedAt: time.Now()},
		deadline:               deadline,
		speculativeAt:          deadline / 2,
		refundReservation:      func() {},
		excludeProviders:       make(map[string]struct{}),
		requestedMaxTokens:     16,
		estimatedPromptTokens:  1,
		parallelToolCalls:      true,
		requestedStopSequences: []string{"stop"},
		profile:                rp,
	}
}

// queuedPlaceholder returns the attempt the queue path created. Attempt 0's
// reserve-only profile (no provider available) sits next to it; the
// placeholder is the one that was enqueued.
func queuedPlaceholder(t *testing.T, rp *registry.RequestProfile) *registry.AttemptProfile {
	t.Helper()
	for _, a := range rp.Attempts() {
		if a.Get(registry.StampQueued) != 0 {
			return a
		}
	}
	t.Fatalf("no queued placeholder attempt among %d attempts", len(rp.Attempts()))
	return nil
}

func TestQueuedAttemptWriteFailureClosesNotDispatched(t *testing.T) {
	s := newTestController(t)
	s.deps.Registry().SetQueue(registry.NewRequestQueue(4, 5*time.Second))
	const model = "queue-write-failure"
	rp := registry.NewRequestProfile(time.Now(), "coord-queue-write", nil, 0)
	d := queueDispatchState(s, model, rp, httptest.NewRequest(http.MethodPost, "/v1/completions", nil), 10*time.Second)
	outcome := make(chan dispatchOutcome, 1)
	go func() { outcome <- d.dispatchPrimary() }()
	// Register the provider only once the request is queued, or attempt 0
	// would reserve it directly and never take the queue path.
	waitForAdaptiveCondition(t, 3*time.Second, func() bool {
		return s.deps.Registry().Queue().QueueSize(model) >= 1
	})
	p := makeRoutableProvider(t, s.deps.Registry(), "queue-write-failure-provider", model) // nil Conn: the frame write fails
	s.deps.Registry().DrainQueuedRequestsForModel(model)

	select {
	case got := <-outcome:
		if got != outcomeRetry {
			t.Fatalf("dispatchPrimary=%v, want retry after the write failure", got)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("dispatchPrimary did not return")
	}
	if d.lastErr != "failed to send request to provider" {
		t.Fatalf("lastErr=%q, want the write failure", d.lastErr)
	}
	ap := queuedPlaceholder(t, rp)
	if ap.Finalized() || !ap.TerminalRecorded() {
		t.Fatalf("failure site must close only the terminal half: finalized=%v terminal=%v", ap.Finalized(), ap.TerminalRecorded())
	}
	ap.CompleteHandler() // what finalizeProfile does once the dispatch loop returns
	if !ap.Finalized() {
		t.Fatal("attempt must finalize once the handler half lands")
	}
	rec := (profiling.Builder{}).Build(rp, ap)
	if rec.ProviderOutcome != "not_dispatched" || rec.FinalStatus != "error" || rec.ErrorReason != "provider_error" {
		t.Fatalf("outcome = %q/%q/%q, want not_dispatched/error/provider_error", rec.ProviderOutcome, rec.FinalStatus, rec.ErrorReason)
	}
	if rec.ProviderID != p.ID || rec.DequeuedUS == nil || rec.WriteSubmittedUS == nil || rec.WriteDoneUS != nil {
		t.Fatalf("row must show the queue handover and a submitted-but-never-done write: provider=%q dequeued=%v submitted=%v done=%v",
			rec.ProviderID, rec.DequeuedUS, rec.WriteSubmittedUS, rec.WriteDoneUS)
	}
}

// TestCloseQueuedAttemptKeepsRecordedErrorText pins the defaulting rule of the
// queue-path close: a real error text with no HTTP status keeps its own class
// (only the code is defaulted); an exit that recorded nothing is classified by
// how the wait ended; a dispatched attempt is left to its provider terminal.
func TestCloseQueuedAttemptKeepsRecordedErrorText(t *testing.T) {
	s := newTestController(t)
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	newReq := func() *http.Request { return httptest.NewRequest(http.MethodPost, "/v1/completions", nil) }

	d := &execution{s: s, r: newReq()}
	d.setLastError("no provider with E2E encryption", 0)
	enc := rp.NewAttempt("enc", 0, "")
	d.closeQueuedAttempt(enc)
	if _, reason, _, po, _ := enc.Outcome(); reason != "encryption_missing" || po != "not_dispatched" {
		t.Fatalf("encryption failure recorded as %q/%q, want encryption_missing/not_dispatched", reason, po)
	}

	d = &execution{s: s, r: newReq()}
	none := rp.NewAttempt("none", 1, "")
	d.closeQueuedAttempt(none)
	if fs, reason, _, po, _ := none.Outcome(); fs != "rejected" || reason != "provider_error" || po != "not_dispatched" {
		t.Fatalf("queue refusal recorded as %q/%q/%q", fs, reason, po)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d = &execution{s: s, r: newReq().WithContext(ctx)}
	gone := rp.NewAttempt("gone", 2, "")
	d.closeQueuedAttempt(gone)
	if fs, _, _, po, _ := gone.Outcome(); fs != "cancelled" || po != "not_dispatched" {
		t.Fatalf("client gone while queued recorded as %q/%q", fs, po)
	}

	d = &execution{s: s, r: newReq()}
	d.setLastError("failed to send request to provider", 0)
	sent := rp.NewAttempt("sent", 3, "")
	sent.Mark(registry.StampWriteDone)
	d.closeQueuedAttempt(sent)
	if fs, _, _, po, _ := sent.Outcome(); fs != "" || po != "" || sent.TerminalRecorded() {
		t.Fatalf("a dispatched attempt must be left alone: %q/%q terminal=%v", fs, po, sent.TerminalRecorded())
	}
}

// TestQueuedAttemptExitsCarryRouteOutcome drives each exit of the queue wait
// through the real dispatchPrimary and asserts the placeholder attempt carries
// the same final_status/error_reason the route outcome records there. During
// the wait d.pr is nil, so updateRoutingOutcome never reaches the attempt
// profile; before the fix these rows were closed with the code-based default
// (rejected|cancelled / provider_error) instead of the routes vocabulary.
// queue_full has no route outcome at all (the routing decision is recorded
// only after a successful enqueue), so it carries the rejection vocabulary.
func TestQueuedAttemptExitsCarryRouteOutcome(t *testing.T) {
	const model = "queue-exit-outcome"
	failQueued := func(reason error) func(*testing.T, *Controller, context.CancelFunc) {
		return func(t *testing.T, s *Controller, _ context.CancelFunc) {
			req := s.deps.Registry().Queue().PopNextFresh(model)
			if req == nil {
				t.Fatal("no queued request to fail")
			}
			req.FailureReason = reason // nil → ErrQueueTimeout
			req.ResponseCh <- nil
		}
	}
	cases := []struct {
		name        string
		maxSize     int
		deadline    time.Duration
		trigger     func(*testing.T, *Controller, context.CancelFunc) // nil: the exit fires on its own
		wantOutcome dispatchOutcome
		wantStatus  string
		wantReason  string
	}{
		{"queue_full", 0, 10 * time.Second, nil, outcomeResponseWritten, "rejected", "queue_full"},
		{"client_gone", 4, 10 * time.Second, func(_ *testing.T, _ *Controller, cancel context.CancelFunc) { cancel() }, outcomeClientGone, "cancelled", "client_gone"},
		// The queue-wait first-content expiry is the queue's own terminal
		// (queue_deadline), kept distinct from a dispatched provider's silence.
		{"queue_deadline", 4, 200 * time.Millisecond, nil, outcomeFailFast, "timeout", RejectionReasonQueueDeadline},
		{"ttft_too_slow", 4, 10 * time.Second, failQueued(registry.ErrQueueTTFTTooSlow), outcomeResponseWritten, "error", "ttft_too_slow"},
		{"model_capability_unsupported", 4, 10 * time.Second, failQueued(registry.ErrQueueToolConstraintUnavailable), outcomeResponseWritten, "error", "model_capability_unsupported"},
		{"queue_timeout", 4, 10 * time.Second, failQueued(nil), outcomeResponseWritten, "timeout", "queue_timeout"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestController(t)
			s.deps.Registry().SetQueue(registry.NewRequestQueue(tc.maxSize, 5*time.Second))
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			rp := registry.NewRequestProfile(time.Now(), "coord-"+tc.name, nil, 0)
			d := queueDispatchState(s, model, rp, httptest.NewRequest(http.MethodPost, "/v1/completions", nil).WithContext(ctx), tc.deadline)
			outcome := make(chan dispatchOutcome, 1)
			go func() { outcome <- d.dispatchPrimary() }()
			if tc.trigger != nil {
				waitForAdaptiveCondition(t, 3*time.Second, func() bool {
					return s.deps.Registry().Queue().QueueSize(model) >= 1
				})
				tc.trigger(t, s, cancel)
			}
			select {
			case got := <-outcome:
				if got != tc.wantOutcome {
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
			rec := (profiling.Builder{}).Build(rp, ap)
			if rec.FinalStatus != tc.wantStatus || rec.ErrorReason != tc.wantReason || rec.ProviderOutcome != "not_dispatched" {
				t.Fatalf("row = %q/%q/%q, want %s/%s/not_dispatched", rec.FinalStatus, rec.ErrorReason, rec.ProviderOutcome, tc.wantStatus, tc.wantReason)
			}
		})
	}
}
