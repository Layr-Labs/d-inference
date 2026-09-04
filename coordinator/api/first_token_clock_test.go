package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestFirstTokenRemainingSince(t *testing.T) {
	t.Parallel()
	if got := firstTokenRemainingSince(time.Time{}, 9*time.Second); got != 9*time.Second {
		t.Fatalf("zero receivedAt: got %s want 9s", got)
	}
	if got := firstTokenRemainingSince(time.Now(), 0); got != 0 {
		t.Fatalf("zero deadline: got %s", got)
	}
	got := firstTokenRemainingSince(time.Now().Add(-8*time.Second), 9*time.Second)
	if got < 500*time.Millisecond || got > 1500*time.Millisecond {
		t.Fatalf("8s-old receive against 9s deadline: remaining=%s", got)
	}
	if got := firstTokenRemainingSince(time.Now().Add(-15*time.Second), 9*time.Second); got != 0 {
		t.Fatalf("expired clock: got %s want 0", got)
	}
}

func TestFirstContentBudgetMillis(t *testing.T) {
	t.Parallel()

	if got, ok := firstContentBudgetMillis(time.Time{}, 9*time.Second); !ok || got != 0 {
		t.Fatalf("unstamped clock = (%d,%v), want omitted+dispatchable", got, ok)
	}

	got, ok := firstContentBudgetMillis(
		time.Now().Add(-8*time.Second), 9*time.Second)
	if !ok || got < 500 || got > 1500 {
		t.Fatalf("remaining budget = (%d,%v), want about 1000ms", got, ok)
	}

	if got, ok := firstContentBudgetMillis(
		time.Now().Add(-15*time.Second), 9*time.Second); ok || got != 0 {
		t.Fatalf("expired clock = (%d,%v), want zero+blocked", got, ok)
	}
}

func TestFirstTokenExpiredAndPreambleCap(t *testing.T) {
	t.Parallel()
	d := &dispatchState{
		deadline: 9 * time.Second,
		timing:   &registry.RequestTiming{ReceivedAt: time.Now().Add(-15 * time.Second)},
	}
	if !d.firstTokenExpired() {
		t.Fatal("expected first-token clock to be expired")
	}
	if d.canExtendPreambleLiveness() {
		t.Fatal("expired clock must not extend preamble liveness")
	}
	if remaining, ok := d.firstTokenRemaining(); !ok || remaining != 0 {
		t.Fatalf("remaining=%s ok=%v", remaining, ok)
	}

	relative := &dispatchState{deadline: 9 * time.Second}
	if relative.firstTokenExpired() {
		t.Fatal("unset ReceivedAt must keep historical relative timers")
	}
	if got := relative.firstTokenWait(4 * time.Second); got != 4*time.Second {
		t.Fatalf("relative fallback: got %s", got)
	}
}

func firstTokenWaitState(t *testing.T, receivedAgo, deadline time.Duration) (*dispatchState, *registry.PendingRequest) {
	t.Helper()
	s := newTestServerForDispatch(t)
	st, ok := s.store.(*store.MemoryStore)
	if !ok {
		t.Fatalf("store = %T", s.store)
	}
	const model = "first-token-deadline-model"
	provider := s.registry.Register("first-token-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat"}},
	})
	receivedAt := time.Now().Add(-receivedAgo)
	pr := &registry.PendingRequest{
		RequestID:            "first-token-request",
		Attempt:              0,
		FirstContentDeadline: receivedAt.Add(deadline),
		ProviderID:           provider.ID,
		Model:                model,
		ChunkCh:              make(chan registry.ProviderChunk, 1),
		AcceptedCh:           make(chan struct{}, 1),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
		Timing:               &registry.RequestTiming{ReceivedAt: receivedAt},
	}
	provider.AddPending(pr)
	if err := st.RecordInferenceRoute(&store.InferenceRouteRecord{
		RequestID:  pr.RequestID,
		Attempt:    pr.Attempt,
		ProviderID: provider.ID,
		Model:      model,
	}); err != nil {
		t.Fatalf("record route: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	if err != nil {
		t.Fatal(err)
	}
	d := &dispatchState{
		s:                 s,
		r:                 req,
		model:             model,
		deadline:          deadline,
		speculativeAt:     deadline / 2,
		timing:            pr.Timing,
		attempt:           0,
		excludeProviders:  make(map[string]struct{}),
		refundReservation: func() {},
		provider:          provider,
		pr:                pr,
		requestID:         pr.RequestID,
	}
	return d, pr
}

func TestWaitAcceptedKeepsRequestAbsoluteDeadline(t *testing.T) {
	d, _ := firstTokenWaitState(t, 8*time.Second, 9*time.Second)
	start := time.Now()
	got := d.waitAccepted()
	elapsed := time.Since(start)
	if got != outcomeRetry {
		t.Fatalf("waitAccepted=%v want outcomeRetry", got)
	}
	if d.lastErrCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d want 504", d.lastErrCode)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("accepted wait used leftover SLA, but took %s (would be 600s before the fix)", elapsed)
	}
}

func TestWaitFirstChunkAcceptDoesNotResetFirstTokenClock(t *testing.T) {
	d, pr := firstTokenWaitState(t, 0, 200*time.Millisecond)
	pr.AcceptedCh <- struct{}{}
	start := time.Now()
	if got := d.waitFirstChunk(); got != outcomeRetry {
		t.Fatalf("waitFirstChunk=%v want timer-driven outcomeRetry", got)
	}
	elapsed := time.Since(start)
	if d.lastErrCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d want 504", d.lastErrCode)
	}
	if elapsed > 1500*time.Millisecond {
		t.Fatalf("accept must not grant inferenceTimeout; elapsed=%s", elapsed)
	}
	if elapsed < 100*time.Millisecond {
		t.Fatalf("should have waited leftover first-token budget; elapsed=%s", elapsed)
	}
}

func TestWaitFirstChunkLaunchesBackupAfterPendingBoilerplateClassification(t *testing.T) {
	d, pr := firstTokenWaitState(t, 0, 150*time.Millisecond)
	d.speculativeAt = 20 * time.Millisecond
	speculativeStarted := make(chan struct{})
	speculativeDeferred := make(chan struct{})
	d.onSpeculativeDispatch = func() {
		close(speculativeStarted)
	}
	d.onSpeculativeDeferral = func() {
		close(speculativeDeferred)
	}

	got, receivedAt := d.provider.BeginPendingChunkIngress(pr.RequestID)
	if got != pr || receivedAt.IsZero() {
		t.Fatal("setup: failed to publish pending chunk ingress")
	}
	resultCh := make(chan dispatchOutcome, 1)
	go func() {
		resultCh <- d.waitFirstChunk()
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

	if got := <-resultCh; got != outcomeRetry {
		t.Fatalf("waitFirstChunk = %v, want timeout retry after speculative attempt", got)
	}
	select {
	case <-speculativeStarted:
	default:
		t.Fatal("pending boilerplate classification consumed speculative launch")
	}
}

func TestFirstTokenSpeculativeWaitUsesAbsoluteClock(t *testing.T) {
	t.Parallel()
	d := &dispatchState{
		deadline:      9 * time.Second,
		speculativeAt: 4500 * time.Millisecond,
		timing:        &registry.RequestTiming{ReceivedAt: time.Now().Add(-4400 * time.Millisecond)},
	}
	got := d.firstTokenSpeculativeWait()
	if got < 50*time.Millisecond || got > 200*time.Millisecond {
		t.Fatalf("dispatch at 4.4s against 4.5s speculative point: wait=%s want ~100ms", got)
	}

	past := &dispatchState{
		deadline:      9 * time.Second,
		speculativeAt: 4500 * time.Millisecond,
		timing:        &registry.RequestTiming{ReceivedAt: time.Now().Add(-5 * time.Second)},
	}
	if got := past.firstTokenSpeculativeWait(); got != 0 {
		t.Fatalf("past speculative point: wait=%s want 0 (start backup now)", got)
	}

	relative := &dispatchState{deadline: 9 * time.Second, speculativeAt: 4500 * time.Millisecond}
	if got := relative.firstTokenSpeculativeWait(); got != 4500*time.Millisecond {
		t.Fatalf("unset ReceivedAt must keep relative speculativeAt: got %s", got)
	}
}

func TestAbandonInflightCancelsDispatchedRequest(t *testing.T) {
	d, pr := firstTokenWaitState(t, 15*time.Second, 9*time.Second)
	provider := d.provider
	if provider.GetPending(pr.RequestID) == nil {
		t.Fatal("setup: request should be pending before abandon")
	}
	if !d.abandonInflightForFirstTokenTimeout() {
		t.Fatal("silent request should be owned by timeout cleanup")
	}
	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("leftover-0 timeout must cancelDispatch the in-flight request")
	}
	if d.provider != nil || d.pr != nil {
		t.Fatal("abandon must clear provider/pr so exhausted cannot settle the attempt")
	}
	if d.lastErrCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d want 504", d.lastErrCode)
	}
	if _, excluded := d.excludeProviders[provider.ID]; !excluded {
		t.Fatal("abandoned provider must be excluded from further attempts")
	}
}

func TestAbandonInflightDefersToPublishedIngress(t *testing.T) {
	d, pr := firstTokenWaitState(t, 15*time.Second, 9*time.Second)
	provider := d.provider
	got, receivedAt := provider.BeginPendingChunkIngress(pr.RequestID)
	if got != pr || receivedAt.IsZero() {
		t.Fatal("setup: failed to publish provider ingress")
	}
	pr.FirstContentDeadline = receivedAt.Add(time.Second)

	if d.abandonInflightForFirstTokenTimeout() {
		t.Fatal("timeout cleanup stole a request with on-time ingress under classification")
	}
	if provider.GetPending(pr.RequestID) != pr {
		t.Fatal("request with on-time ingress was removed")
	}
	if d.provider != provider || d.pr != pr {
		t.Fatal("dispatch ownership was cleared before ingress classification")
	}

	pr.FinishProviderChunkIngress(receivedAt, true)
	d.s.cancelDispatch(provider, pr, cancelCauseFirstChunkTimeout)
}

func TestWriteFirstTokenTimeoutUsesOpenRouter429Contract(t *testing.T) {
	s := newTestServerForDispatch(t)
	rec := httptest.NewRecorder()
	s.writeFirstTokenTimeout(rec, "", "m", "provider did not respond within TTFT deadline")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d want 429", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Fatal("Retry-After header missing")
	}
	if _, err := strconv.Atoi(rec.Header().Get("Retry-After")); err != nil {
		t.Fatalf("Retry-After=%q want integer seconds", rec.Header().Get("Retry-After"))
	}
	body := rec.Body.String()
	if !strings.Contains(body, "rate_limit_exceeded") {
		t.Fatalf("body missing rate_limit_exceeded: %s", body)
	}
	if strings.Contains(body, "first_chunk_timeout") {
		t.Fatalf("client body must not use first_chunk_timeout: %s", body)
	}
}

func TestProviderAttributableStall(t *testing.T) {
	t.Parallel()
	if providerAttributableStall(preambleContentTimeout - time.Second) {
		t.Fatal("a wait capped below the preamble-content window is OUR clock, not provider fault")
	}
	if !providerAttributableStall(preambleContentTimeout) {
		t.Fatal("a full preamble-content window of silence is provider-attributable")
	}
	if !providerAttributableStall(inferenceTimeout) {
		t.Fatal("the historical uncapped accepted budget must stay provider-attributable")
	}
	pr := &registry.PendingRequest{
		Timing: &registry.RequestTiming{
			DispatchedAt: time.Now().Add(-preambleContentTimeout - time.Second),
		},
	}
	if !providerAttemptAttributableStall(pr, time.Second) {
		t.Fatal("full initial provider interval must count even when extension is short")
	}
}

func TestFirstTokenWriteContext(t *testing.T) {
	t.Parallel()
	base := context.Background()

	ctx, cancel := firstTokenWriteContext(base, time.Time{}, 9*time.Second)
	if _, ok := ctx.Deadline(); ok {
		t.Fatal("zero receivedAt must pass the context through unbounded")
	}
	cancel()

	receivedAt := time.Now().Add(-8 * time.Second)
	ctx, cancel = firstTokenWriteContext(base, receivedAt, 9*time.Second)
	defer cancel()
	dl, ok := ctx.Deadline()
	if !ok {
		t.Fatal("request clock set: write context must carry the first-token deadline")
	}
	if want := receivedAt.Add(9 * time.Second); !dl.Equal(want) {
		t.Fatalf("deadline=%s want %s", dl, want)
	}

	expired, cancelExpired := firstTokenWriteContext(base, time.Now().Add(-15*time.Second), 9*time.Second)
	defer cancelExpired()
	select {
	case <-expired.Done():
	case <-time.After(time.Second):
		t.Fatal("an already-expired clock must yield an already-done write context")
	}
}

func TestGenericDispatchQueueWaitUsesAbsoluteDeadline(t *testing.T) {
	s := newTestServerForDispatch(t)
	s.registry.SetQueue(registry.NewRequestQueue(4, 5*time.Second))
	req := httptest.NewRequest(http.MethodPost, "/v1/completions", nil)
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	d := &dispatchState{
		s:                      s,
		w:                      httptest.NewRecorder(),
		r:                      req,
		model:                  "generic-queue-deadline",
		publicModel:            "generic-queue-deadline",
		rawBody:                []byte(`{"model":"generic-queue-deadline","messages":[]}`),
		consumerEndpoint:       completionsEndpoint,
		timing:                 timing,
		deadline:               50 * time.Millisecond,
		speculativeAt:          25 * time.Millisecond,
		refundReservation:      func() {},
		excludeProviders:       make(map[string]struct{}),
		requestedMaxTokens:     16,
		estimatedPromptTokens:  1,
		parallelToolCalls:      true,
		requestedStopSequences: []string{"stop"},
	}
	start := time.Now()
	if got := d.dispatchPrimary(); got != outcomeFailFast {
		t.Fatalf("dispatchPrimary=%v, want deadline fail-fast", got)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("generic queue wait ignored absolute deadline: %v", elapsed)
	}
	if d.lastErrCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d, want synthetic 504 for canonical 429", d.lastErrCode)
	}
	if depth := s.registry.Queue().QueueSize(d.model); depth != 0 {
		t.Fatalf("queue depth=%d after absolute expiry, want 0", depth)
	}
}

func TestDrainReadyFirstContentPrefersBufferedToken(t *testing.T) {
	t.Parallel()
	deadline := time.Now().Add(time.Second)
	pr := &registry.PendingRequest{
		FirstContentDeadline: deadline,
		ChunkCh:              make(chan registry.ProviderChunk, 2),
	}
	var held []string
	if _, ok := drainReadyFirstContent(pr, &held); ok {
		t.Fatal("empty channel must not produce content")
	}
	pr.ChunkCh <- registry.ProviderChunk{
		Data:       "hello-token",
		ReceivedAt: deadline.Add(-time.Millisecond),
	}
	chunk, ok := drainReadyFirstContent(pr, &held)
	if !ok || chunk.Data != "hello-token" {
		t.Fatalf("drain=%q ok=%v want buffered token", chunk, ok)
	}
	closed := &registry.PendingRequest{ChunkCh: make(chan registry.ProviderChunk)}
	close(closed.ChunkCh)
	if _, ok := drainReadyFirstContent(closed, &held); ok {
		t.Fatal("closed channel must fall through to the timeout path")
	}
}

func TestDrainReadyFirstContentDropsExcessBoilerplate(t *testing.T) {
	pr := &registry.PendingRequest{ChunkCh: make(chan registry.ProviderChunk, maxHeldBoilerplate+2)}
	for i := 0; i < maxHeldBoilerplate+1; i++ {
		pr.ChunkCh <- registry.ProviderChunk{Data: roleOnlyChunkSSE("m")}
	}
	pr.ChunkCh <- registry.ProviderChunk{Data: contentChunkSSE("m", "real-content")}
	var held []string
	chunk, ok := drainReadyFirstContent(pr, &held)
	if !ok || chunk.Data != contentChunkSSE("m", "real-content") {
		t.Fatalf("drain returned ok=%v chunk=%q, want real content", ok, chunk)
	}
	if len(held) != maxHeldBoilerplate {
		t.Fatalf("held boilerplate=%d, want bounded %d", len(held), maxHeldBoilerplate)
	}
}

func TestBufferedContentBeatsReadyErrorAndPreservesNativeMessagesTerminal(t *testing.T) {
	d, pr := firstTokenWaitState(t, 0, time.Second)
	pr.ConsumerEndpoint = messagesEndpoint
	pr.PublicModel = "public-model"
	pr.ChunkCh <- registry.ProviderChunk{
		Data:       contentChunkSSE("m", "partial"),
		ReceivedAt: time.Now(),
	}
	errMsg := protocol.InferenceErrorMessage{
		RequestID:  pr.RequestID,
		Error:      "generation failed",
		StatusCode: http.StatusInternalServerError,
	}

	if !d.commitReadyFirstContent(pr, &d.heldChunks, errMsg) {
		t.Fatal("buffered on-time content lost to ready terminal error")
	}
	if d.initialError == nil || d.initialError.Error != errMsg.Error {
		t.Fatal("consumed terminal error was not preserved for response handoff")
	}

	recorder := httptest.NewRecorder()
	d.s.handleStreamingResponseWithFirstChunkAndError(
		recorder, d.r, pr, []string{d.firstChunk}, d.initialError)
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

func TestWaitFirstChunkRejectsBufferedContentAfterAbsoluteDeadline(t *testing.T) {
	d, pr := firstTokenWaitState(t, 15*time.Second, 9*time.Second)
	pr.ChunkCh <- registry.ProviderChunk{
		Data:       "late-token",
		ReceivedAt: pr.FirstContentDeadline.Add(time.Millisecond),
	}
	if got := d.waitFirstChunk(); got != outcomeRetry {
		t.Fatalf("waitFirstChunk=%v want outcomeRetry for post-deadline content", got)
	}
	if d.committed || d.firstChunk != "" {
		t.Fatalf("committed=%v firstChunk=%q", d.committed, d.firstChunk)
	}
	if d.lastErrCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d, want 504 for canonical deadline 429", d.lastErrCode)
	}
}

func TestWaitFirstChunkAcceptsBufferedOnTimeContentAfterTimerExpiry(t *testing.T) {
	d, pr := firstTokenWaitState(t, 15*time.Second, 9*time.Second)
	pr.ChunkCh <- registry.ProviderChunk{
		Data:       "on-time-token",
		ReceivedAt: pr.FirstContentDeadline.Add(-time.Millisecond),
	}
	if got := d.waitFirstChunk(); got != outcomeCommitted {
		t.Fatalf("waitFirstChunk=%v, want outcomeCommitted for on-time ingress", got)
	}
	if !d.committed || d.firstChunk != "on-time-token" {
		t.Fatalf("committed=%v firstChunk=%q", d.committed, d.firstChunk)
	}
}

func TestWaitFirstChunkPreservesOnTimeEmptyCompletionDuringSettlement(t *testing.T) {
	d, pr := firstTokenWaitState(t, 2*time.Second, time.Second)
	pr.MarkCompletionIngress(pr.FirstContentDeadline.Add(-time.Millisecond))

	resultCh := make(chan dispatchOutcome, 1)
	go func() {
		resultCh <- d.waitFirstChunk()
	}()

	select {
	case got := <-resultCh:
		t.Fatalf("on-time completion timed out during settlement: %v", got)
	case <-time.After(50 * time.Millisecond):
	}
	pr.CompleteCh <- protocol.UsageInfo{}
	close(pr.ChunkCh)
	if got := <-resultCh; got != outcomeCommitted {
		t.Fatalf("waitFirstChunk=%v, want committed on-time empty completion", got)
	}
	if !d.committed {
		t.Fatal("on-time empty completion was not committed")
	}
}

func TestPendingChunkIngressIsVisibleBeforeClassification(t *testing.T) {
	pr := &registry.PendingRequest{}
	receivedAt := pr.BeginProviderChunkIngress()
	pr.FirstContentDeadline = receivedAt.Add(time.Millisecond)
	if !pr.FirstContentIngressArrivedByDeadline() {
		t.Fatal("on-time chunk under classification was invisible to deadline arbitration")
	}
	if !pr.FinishProviderChunkIngress(receivedAt, true) {
		t.Fatal("first content classification was not claimed")
	}
	if !pr.FirstContentIngressArrivedByDeadline() {
		t.Fatal("classified on-time content became invisible before channel delivery")
	}
}

func TestEmptyCompletionOnlyPrecedesLaterSpeculativeContent(t *testing.T) {
	deadline := time.Now().Add(time.Second)
	empty := &registry.PendingRequest{FirstContentDeadline: deadline}
	completedAt := deadline.Add(-500 * time.Millisecond)
	empty.MarkCompletionIngress(completedAt)

	if !emptyCompletionPrecedesChunk(empty, registry.ProviderChunk{
		Data:       "later",
		ReceivedAt: completedAt.Add(time.Millisecond),
	}) {
		t.Fatal("earlier empty completion did not win speculative ingress ordering")
	}
	if emptyCompletionPrecedesChunk(empty, registry.ProviderChunk{
		Data:       "earlier",
		ReceivedAt: completedAt.Add(-time.Millisecond),
	}) {
		t.Fatal("later empty completion displaced earlier speculative content")
	}
}

func TestAbandonInflightOverridesStaleError(t *testing.T) {
	d, _ := firstTokenWaitState(t, 15*time.Second, 9*time.Second)
	d.setLastError("failed to send request to provider", http.StatusBadGateway)
	d.abandonInflightForFirstTokenTimeout()
	if d.lastErrCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d want the synthetic 504 (exhausted ladder remaps to 429), not a leaked 502", d.lastErrCode)
	}
}
