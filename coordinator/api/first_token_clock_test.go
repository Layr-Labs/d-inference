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
	pr := &registry.PendingRequest{
		RequestID:  "first-token-request",
		Attempt:    0,
		ProviderID: provider.ID,
		Model:      model,
		ChunkCh:    make(chan string, 1),
		AcceptedCh: make(chan struct{}, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		Timing:     &registry.RequestTiming{ReceivedAt: time.Now().Add(-receivedAgo)},
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
	if got := d.waitFirstChunk(); got != outcomeAccepted {
		t.Fatalf("waitFirstChunk=%v want outcomeAccepted", got)
	}
	if got := d.waitAccepted(); got != outcomeRetry {
		t.Fatalf("waitAccepted=%v want outcomeRetry", got)
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
	d.abandonInflightForFirstTokenTimeout()
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

func TestWriteFirstTokenTimeoutUsesOpenRouter429Contract(t *testing.T) {
	s := newTestServerForDispatch(t)
	rec := httptest.NewRecorder()
	s.writeFirstTokenTimeout(rec, "m", "provider did not respond within TTFT deadline")
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

func TestDrainReadyFirstContentPrefersBufferedToken(t *testing.T) {
	t.Parallel()
	pr := &registry.PendingRequest{ChunkCh: make(chan string, 2)}
	var held []string
	if _, ok := drainReadyFirstContent(pr, &held); ok {
		t.Fatal("empty channel must not produce content")
	}
	pr.ChunkCh <- "hello-token"
	chunk, ok := drainReadyFirstContent(pr, &held)
	if !ok || chunk != "hello-token" {
		t.Fatalf("drain=%q ok=%v want buffered token", chunk, ok)
	}
	closed := &registry.PendingRequest{ChunkCh: make(chan string)}
	close(closed.ChunkCh)
	if _, ok := drainReadyFirstContent(closed, &held); ok {
		t.Fatal("closed channel must fall through to the timeout path")
	}
}

func TestWaitFirstChunkDeliversBufferedTokenOnExpiredClock(t *testing.T) {
	d, pr := firstTokenWaitState(t, 15*time.Second, 9*time.Second)
	pr.ChunkCh <- "hello-token"
	if got := d.waitFirstChunk(); got != outcomeCommitted {
		t.Fatalf("waitFirstChunk=%v want outcomeCommitted — an on-time buffered token must beat the expired clock", got)
	}
	if !d.committed || d.firstChunk != "hello-token" {
		t.Fatalf("committed=%v firstChunk=%q", d.committed, d.firstChunk)
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
