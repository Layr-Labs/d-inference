package inference_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWaitFirstChunkAcceptDoesNotResetFirstTokenClock(t *testing.T) {
	d, pr := newContentWaitFixture(t, 0, 200*time.Millisecond)
	pr.AcceptedCh <- struct{}{}
	start := time.Now()
	if got := d.first(); got != attempt.Retry {
		t.Fatalf("waitFirstChunk=%v want timer-driven outcomeRetry", got)
	}
	elapsed := time.Since(start)
	if d.failure.Message.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d want 504", d.failure.Message.StatusCode)
	}
	if elapsed > 1500*time.Millisecond {
		t.Fatalf("accept must not grant inferenceTimeout; elapsed=%s", elapsed)
	}
	if elapsed < 100*time.Millisecond {
		t.Fatalf("should have waited leftover first-token budget; elapsed=%s", elapsed)
	}
}

func TestWaitFirstChunkLaunchesBackupAfterPendingBoilerplateClassification(t *testing.T) {
	d, pr := newContentWaitFixture(t, 0, 150*time.Millisecond)
	d.speculativeAt = 20 * time.Millisecond
	speculativeStarted := make(chan struct{})
	speculativeDeferred := make(chan struct{})
	deps := d.firstDependencies()
	launch := deps.Speculate
	deps.Speculate = func() attempt.Outcome {
		close(speculativeStarted)
		return launch()
	}
	deps.Ingress = &speculativeIngressBarrier{Ingress: deps.Ingress, deferred: speculativeDeferred}
	waiter := attempt.NewFirstWait(deps, d.firstConfig())

	got, receivedAt := d.provider.BeginPendingChunkIngress(pr.RequestID)
	if got != pr || receivedAt.IsZero() {
		t.Fatal("setup: failed to publish pending chunk ingress")
	}
	resultCh := make(chan attempt.Outcome, 1)
	go func() {
		resultCh <- d.firstWith(waiter)
	}()

	select {
	case <-speculativeDeferred:
	case <-time.After(time.Second):
		t.Fatal("speculative timer did not defer to pending ingress")
	}
	pr.FinishProviderChunkIngress(receivedAt, false)
	pr.ChunkCh <- registry.ProviderChunk{
		Data:       roleOnlyChunkSSE("m"),
		ReceivedAt: receivedAt,
	}

	if got := <-resultCh; got != attempt.Retry {
		t.Fatalf("waitFirstChunk = %v, want timeout retry after speculative attempt", got)
	}
	select {
	case <-speculativeStarted:
	default:
		t.Fatal("pending boilerplate classification consumed speculative launch")
	}
}

// The barrier delegates the actual ingress decision; it cannot independently
// trigger or suppress a launch as an observer callback could.
type speculativeIngressBarrier struct {
	attempt.Ingress
	deferred chan struct{}
	once     sync.Once
}

func (b *speculativeIngressBarrier) Pending(pr *registry.PendingRequest) bool {
	pending := b.Ingress.Pending(pr)
	if pending {
		b.once.Do(func() { close(b.deferred) })
	}
	return pending
}

func TestWaitFirstChunkRejectsBufferedContentAfterAbsoluteDeadline(t *testing.T) {
	d, pr := newContentWaitFixture(t, 15*time.Second, 9*time.Second)
	pr.ChunkCh <- registry.ProviderChunk{
		Data:       "late-token",
		ReceivedAt: pr.FirstContentDeadline.Add(time.Millisecond),
	}
	if got := d.first(); got != attempt.Retry {
		t.Fatalf("waitFirstChunk=%v want outcomeRetry for post-deadline content", got)
	}
	committed := d.result.Outcome == attempt.Committed
	if committed || d.content.FirstChunk != "" {
		t.Fatalf("committed=%v firstChunk=%q", committed, d.content.FirstChunk)
	}
	if d.failure.Message.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d, want 504 for canonical deadline 429", d.failure.Message.StatusCode)
	}
}

func TestWaitFirstChunkAcceptsBufferedOnTimeContentAfterTimerExpiry(t *testing.T) {
	d, pr := newContentWaitFixture(t, 15*time.Second, 9*time.Second)
	pr.ChunkCh <- registry.ProviderChunk{
		Data:       "on-time-token",
		ReceivedAt: pr.FirstContentDeadline.Add(-time.Millisecond),
	}
	if got := d.first(); got != attempt.Committed {
		t.Fatalf("waitFirstChunk=%v, want outcomeCommitted for on-time ingress", got)
	}
	committed := d.result.Outcome == attempt.Committed
	if !committed || d.content.FirstChunk != "on-time-token" {
		t.Fatalf("committed=%v firstChunk=%q", committed, d.content.FirstChunk)
	}
}

// TestHedgeAdvanceRearmsSpeculativeTimerEarlier pins the waitFirstChunk
// re-arm guards: a strictly-earlier probe-refined instant moves the backup
// launch off the 50% point, while a not-earlier value leaves the legacy
// timing untouched (invariant 1 of hedge_schedule.go -- the 50% point is a
// ceiling, never exceeded).
func TestHedgeAdvanceRearmsSpeculativeTimerEarlier(t *testing.T) {
	t.Run("earlier instant launches the backup sooner", func(t *testing.T) {
		d, _ := newContentWaitFixture(t, 0, 1200*time.Millisecond)
		d.speculativeAt = 900 * time.Millisecond
		receivedAt := firstcontent.TimingReceivedAt(d.timing)
		advance := make(chan time.Time, 1)
		advance <- receivedAt.Add(150 * time.Millisecond)
		d.hedgeAdvance = advance

		speculativeStarted := make(chan time.Time, 1)
		deps := d.firstDependencies()
		launch := deps.Speculate
		deps.Speculate = func() attempt.Outcome {
			speculativeStarted <- time.Now()
			return launch()
		}
		waiter := attempt.NewFirstWait(deps, d.firstConfig())

		done := make(chan struct{})
		go func() {
			d.firstWith(waiter)
			close(done)
		}()
		defer func() { <-done }()
		select {
		case at := <-speculativeStarted:
			if since := at.Sub(receivedAt); since > 600*time.Millisecond {
				t.Fatalf("backup launched %s after receipt, want ~150ms (re-armed), not the 900ms default", since)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("speculative launch never fired")
		}
		if d.speculativeAt != 150*time.Millisecond {
			t.Fatalf("speculativeAt=%s after re-arm, want 150ms so downstream windows agree", d.speculativeAt)
		}
	})

	t.Run("not-earlier instant is ignored", func(t *testing.T) {
		d, _ := newContentWaitFixture(t, 0, 1200*time.Millisecond)
		d.speculativeAt = 500 * time.Millisecond
		receivedAt := firstcontent.TimingReceivedAt(d.timing)
		advance := make(chan time.Time, 1)
		// Equal to the armed point: NOT strictly earlier, must not re-arm.
		advance <- receivedAt.Add(500 * time.Millisecond)
		d.hedgeAdvance = advance

		speculativeStarted := make(chan time.Time, 1)
		deps := d.firstDependencies()
		launch := deps.Speculate
		deps.Speculate = func() attempt.Outcome {
			speculativeStarted <- time.Now()
			return launch()
		}
		waiter := attempt.NewFirstWait(deps, d.firstConfig())

		done := make(chan struct{})
		go func() {
			d.firstWith(waiter)
			close(done)
		}()
		defer func() { <-done }()
		select {
		case at := <-speculativeStarted:
			if since := at.Sub(receivedAt); since < 400*time.Millisecond {
				t.Fatalf("backup launched %s after receipt — a not-earlier advance re-armed the timer", since)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("speculative launch never fired")
		}
		if d.speculativeAt != 500*time.Millisecond {
			t.Fatalf("speculativeAt=%s, want the untouched 500ms default", d.speculativeAt)
		}
	})
}

func TestFirstTokenExpiredAndPreambleCap(t *testing.T) {
	t.Parallel()
	clock := firstcontent.NewClock(time.Now().Add(-15*time.Second), 9*time.Second, 0)
	if !clock.Expired() {
		t.Fatal("expected first-token clock to be expired")
	}
	if clock.CanExtendPreamble() {
		t.Fatal("expired clock must not extend preamble liveness")
	}
	if remaining, ok := clock.Remaining(); !ok || remaining != 0 {
		t.Fatalf("remaining=%s ok=%v", remaining, ok)
	}

	relative := firstcontent.NewClock(time.Time{}, 9*time.Second, 0)
	if relative.Expired() {
		t.Fatal("unset ReceivedAt must keep historical relative timers")
	}
	if got := relative.Wait(4 * time.Second); got != 4*time.Second {
		t.Fatalf("relative fallback: got %s", got)
	}
}

func TestFirstTokenSpeculativeWaitUsesAbsoluteClock(t *testing.T) {
	t.Parallel()
	clock := firstcontent.NewClock(time.Now().Add(-4400*time.Millisecond), 9*time.Second, 4500*time.Millisecond)
	got := clock.SpeculativeWait()
	if got < 50*time.Millisecond || got > 200*time.Millisecond {
		t.Fatalf("dispatch at 4.4s against 4.5s speculative point: wait=%s want ~100ms", got)
	}

	past := firstcontent.NewClock(time.Now().Add(-5*time.Second), 9*time.Second, 4500*time.Millisecond)
	if got := past.SpeculativeWait(); got != 0 {
		t.Fatalf("past speculative point: wait=%s want 0 (start backup now)", got)
	}

	relative := firstcontent.NewClock(time.Time{}, 9*time.Second, 4500*time.Millisecond)
	if got := relative.SpeculativeWait(); got != 4500*time.Millisecond {
		t.Fatalf("unset ReceivedAt must keep relative speculativeAt: got %s", got)
	}
}

func TestGenericDispatchQueueWaitUsesAbsoluteDeadline(t *testing.T) {
	s := newTestServerForDispatch(t)
	s.registry.SetQueue(registry.NewRequestQueue(4, 5*time.Second))
	req := httptest.NewRequest(http.MethodPost, "/v1/completions", nil)
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	request := inference.PrimaryRequest{
		Dispatch: providerdispatch.Input{
			Request:               req,
			Scope:                 providerdispatch.Scope{PreferOwner: true, OwnerAccountID: testConsumerID},
			Model:                 "generic-queue-deadline",
			PublicModel:           "generic-queue-deadline",
			Body:                  []byte(`{"model":"generic-queue-deadline","messages":[]}`),
			Timing:                timing,
			Deadline:              50 * time.Millisecond,
			Exclusions:            providerdispatch.NewExclusions(),
			RequestedMaxTokens:    16,
			EstimatedPromptTokens: 1,
			Traits:                registry.RequestTraits{ParallelToolCalls: true},
		},
		Metadata:      providerdispatch.PendingMetadata{Endpoint: inreq.CompletionsEndpoint, StopSequences: []string{"stop"}},
		Writer:        httptest.NewRecorder(),
		SpeculativeAt: 25 * time.Millisecond,
		Refund:        func() {},
	}
	primary := s.NewPrimary(inference.PrimaryResources{})
	start := time.Now()
	result := primary.Run(request)
	if got := result.Outcome; got != attempt.FailFast {
		t.Fatalf("dispatchPrimary=%v, want deadline fail-fast", got)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("generic queue wait ignored absolute deadline: %v", elapsed)
	}
	if result.History.Failure.Message.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d, want synthetic 504 for canonical 429", result.History.Failure.Message.StatusCode)
	}
	if depth := s.registry.Queue().QueueSize(request.Dispatch.Model); depth != 0 {
		t.Fatalf("queue depth=%d after absolute expiry, want 0", depth)
	}
}

func TestBufferedContentBeatsReadyErrorAndPreservesNativeMessagesTerminal(t *testing.T) {
	s, _, pr, req := waitDeadlineFixture(t, 0, time.Second)
	pr.ConsumerEndpoint = inreq.MessagesEndpoint
	pr.PublicModel = "public-model"
	pr.ChunkCh <- registry.ProviderChunk{
		Data:       contentChunkSSE("m", "partial"),
		ReceivedAt: time.Now(),
	}
	errMsg := protocol.InferenceErrorMessage{
		RequestID:   pr.RequestID,
		Error:       "generation failed",
		StatusCode:  http.StatusInternalServerError,
		FailureCode: protocol.FailureCodeGenerationFailure,
	}

	var held []string
	content := s.NewContentCommitter().Buffered(nil, pr, &held, errMsg)
	if content == nil {
		t.Fatal("buffered on-time content lost to ready terminal error")
	}
	if content.InitialError == nil || content.InitialError.Error != errMsg.Error {
		t.Fatal("consumed terminal error was not preserved for response handoff")
	}

	recorder := httptest.NewRecorder()
	s.NewRelay().Stream(recorder, req, pr, []string{content.FirstChunk}, content.InitialError)
	body := recorder.Body.String()
	if !strings.Contains(body, `"text":"partial"`) ||
		!strings.Contains(body, "event: error") ||
		!strings.Contains(body, `"error":{"message":"inference generation failed","type":"api_error"}`) {
		t.Fatalf("messages stream did not preserve content then native error:\n%s", body)
	}
	if strings.Contains(body, `"object":"error"`) || strings.Contains(body, "data: [DONE]") {
		t.Fatalf("messages stream leaked OpenAI terminal framing:\n%s", body)
	}
}

func TestAbandonInflightCancelsDispatchedRequest(t *testing.T) {
	s, provider, pr, _ := waitDeadlineFixture(t, 15*time.Second, 9*time.Second)
	abandon := s.NewInflightAbandon(attempt.TimeoutConfig{
		Model: pr.Model, Provider: provider, Pending: pr, RequestID: pr.RequestID, Attempt: pr.Attempt,
	})
	if provider.GetPending(pr.RequestID) == nil {
		t.Fatal("setup: request should be pending before abandon")
	}
	result := abandon.Run(9 * time.Second)
	if !result.Claimed {
		t.Fatal("silent request should be owned by timeout cleanup")
	}
	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("leftover-0 timeout must cancelDispatch the in-flight request")
	}
	if result.Provider != nil || result.Pending != nil {
		t.Fatal("abandon must clear provider/pr so exhausted cannot settle the attempt")
	}
	if result.Failure.Message.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d want 504", result.Failure.Message.StatusCode)
	}
	if result.ExcludedProviderID != provider.ID {
		t.Fatal("abandoned provider must be excluded from further attempts")
	}
}

func TestAbandonInflightDefersToPublishedIngress(t *testing.T) {
	s, provider, pr, _ := waitDeadlineFixture(t, 15*time.Second, 9*time.Second)
	abandon := s.NewInflightAbandon(attempt.TimeoutConfig{
		Model: pr.Model, Provider: provider, Pending: pr, RequestID: pr.RequestID, Attempt: pr.Attempt,
	})
	got, receivedAt := provider.BeginPendingChunkIngress(pr.RequestID)
	if got != pr || receivedAt.IsZero() {
		t.Fatal("setup: failed to publish provider ingress")
	}
	pr.FirstContentDeadline = receivedAt.Add(time.Second)

	result := abandon.Run(9 * time.Second)
	if result.Claimed {
		t.Fatal("timeout cleanup stole a request with on-time ingress under classification")
	}
	if provider.GetPending(pr.RequestID) != pr {
		t.Fatal("request with on-time ingress was removed")
	}
	if result.Provider != provider || result.Pending != pr {
		t.Fatal("dispatch ownership was cleared before ingress classification")
	}

	pr.FinishProviderChunkIngress(receivedAt, true)
	s.cancels.CancelDispatch(provider, pr, cancellation.CauseFirstChunkTimeout)
}

func TestAbandonInflightOverridesStaleError(t *testing.T) {
	s, provider, pr, _ := waitDeadlineFixture(t, 15*time.Second, 9*time.Second)
	lastFailure := retry.CoordinatorFailure("failed to send request to provider", http.StatusBadGateway)
	result := s.NewInflightAbandon(attempt.TimeoutConfig{
		Model: pr.Model, Provider: provider, Pending: pr, RequestID: pr.RequestID, Attempt: pr.Attempt,
	}).Run(9 * time.Second)
	if result.Claimed {
		lastFailure = result.Failure
	}
	if lastFailure.Message.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d want the synthetic 504 (exhausted ladder remaps to 429), not a leaked 502", lastFailure.Message.StatusCode)
	}
}
