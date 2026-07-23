package api

// Regression tests for incident race #2 on the NON-STREAMING path
// (handleNonStreamingResponseWithFirstChunk, which backs Chat, Responses,
// Completions, and Messages when stream=false).
//
// The gap: the streaming paths gate their client timeout on
// actorAcceptsClientTimeout, but the non-streaming handler's ctx-deadline
// branches unconditionally refunded + 504'd — so a provider terminal that had
// already won the attempt's actor claim (billing in progress / complete on
// another goroutine) could be contradicted by a spurious client timeout. The fix
// makes each deadline branch, when the actor reports a terminal already won, wait
// a bounded providerTerminalGrace on the REAL terminal channel (never on the
// already-fired ctx, which would busy-loop) and deliver the real outcome.

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// bindWonProviderTerminal binds a request actor for pr in the server's actor
// table and has the provider read loop claim the given terminal SYNCHRONOUSLY,
// exactly as providerReadLoop does before launching the slow billing work. This
// is the "a provider terminal already won this attempt" precondition for race #2.
func bindWonProviderTerminal(t *testing.T, srv *Server, prov *registry.Provider, pr *registry.PendingRequest, kind terminalKind) {
	t.Helper()
	prov.AddPending(pr)
	actor, _ := newTestActor(t, srv.actors, nil)
	actor.registerAttempt(pr.RequestID, prov.ID, "primary", 0)
	t.Cleanup(actor.close)
	if !srv.acceptProviderTerminal(prov.ID, prov, pr.RequestID, kind) {
		t.Fatalf("provider %s terminal must be claimed on the read loop", kind)
	}
}

// firedDeadlineCtx returns a context whose one-shot deadline has already elapsed,
// so ctx.Err() is DeadlineExceeded and ctx.Done() stays permanently ready —
// exactly the state handleNonStreamingResponseWithFirstChunk's inner ctx is in
// once the client deadline fires.
func firedDeadlineCtx(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	t.Cleanup(cancel)
	if !errors.Is(ctx.Err(), context.DeadlineExceeded) {
		t.Fatalf("ctx should be DeadlineExceeded, got %v", ctx.Err())
	}
	return ctx
}

// TestNonStreamingOuterLoopDeadlineDefersToWonProviderTerminal is the end-to-end
// regression guard for the outer-loop deadline site. A provider completion wins
// the actor claim (as the read loop would), then the client deadline fires while
// the completion's channel signals are still pending, and only AFTER the deadline
// does the real terminal land — the exact race #2 window. Without the fix the
// handler refunds + 504s on ctx.Done(); with it, it drains the real terminal and
// returns the true 200 response.
//
// Ordering is made deterministic by two ordered context deadlines (not sleeps):
// the client deadline fires first, the terminal is delivered strictly later, so
// the handler is provably in its deadline branch with ChunkCh still open when the
// terminal arrives. The genuine claim race (provider terminal vs client timeout)
// is reproduced at the actor level by pre-claiming the terminal.
func TestNonStreamingOuterLoopDeadlineDefersToWonProviderTerminal(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	prov := srv.registry.Register("prov-outer-race", nil, &protocol.RegisterMessage{})

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)
	const reservedMicroUSD int64 = 25_000
	if err := ledger.Charge(consumerID, reservedMicroUSD, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "outer-loop-race",
		Model:            "race-model",
		ConsumerKey:      consumerID,
		ProviderID:       prov.ID,
		ReservedMicroUSD: reservedMicroUSD,
		ChunkCh:          make(chan string, 4),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	bindWonProviderTerminal(t, srv, prov, pr, terminalComplete)

	// Two ordered deadlines: the client deadline (handlerCtx) fires first; the
	// terminal is delivered strictly after (terminalCtx), i.e. the completion's
	// billing tail finishes just AFTER the client deadline fired.
	handlerCtx, cancelH := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancelH()
	terminalCtx, cancelT := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancelT()

	usage := protocol.UsageInfo{PromptTokens: 3, CompletionTokens: 7}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		<-terminalCtx.Done() // strictly after the client deadline fired
		pr.CompleteCh <- usage
		close(pr.ChunkCh)
		close(pr.CompleteCh)
	}()

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(handlerCtx)
	rr := httptest.NewRecorder()
	completeChunk := `data: {"id":"chatcmpl-outer-race","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"ok"}}]}`

	srv.handleNonStreamingResponseWithFirstChunk(rr, req, pr, []string{completeChunk})
	wg.Wait()

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 — a won provider terminal must not be overridden by a spurious client timeout; body = %s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"content":"ok"`) {
		t.Fatalf("client did not receive the real completion body: %s", rr.Body.String())
	}
	// No spurious refund: the reservation stays held (real billing would settle
	// it; the timeout path would have refunded the whole reserve).
	if pr.IsReservationFinalized() {
		t.Fatal("reservation must not be finalized by the timeout path once a provider terminal won (no spurious refund)")
	}
	if got := ledger.Balance(consumerID); got != initialBalance-reservedMicroUSD {
		t.Fatalf("balance = %d, want held reserve %d (a spurious refund would restore %d)", got, initialBalance-reservedMicroUSD, initialBalance)
	}
}

// TestAwaitCompletionActorRejectGraceReturnsUsage covers the sites-1/2 helper:
// with the client deadline already fired but a provider completion having won the
// actor claim, awaitCompletion must NOT report a timeout — it must fall through to
// the INNER grace select and return the real usage once it arrives.
//
// CompleteCh starts EMPTY (not pre-buffered): if it were already buffered, Go's
// outer select would have two ready cases (fired ctx.Done() AND a ready
// CompleteCh) and could resolve via the ordinary first-case branch by chance,
// passing even if the ctx.Done() branch's actor-reject/grace logic were reverted.
// With CompleteCh empty, the outer select's only ready case is ctx.Done(), so the
// call is forced through the actor-reject branch into the inner grace select.
// Usage is delivered from a goroutine after a delay comfortably larger than the
// outer-to-inner-select transition (an errors.Is check plus one actor mutex
// lock/unlock — microseconds) and comfortably smaller than the shrunk grace
// window — the same real-timer-margin idiom
// TestNonStreamingOuterLoopDeadlineDefersToWonProviderTerminal uses (30ms vs
// 150ms), not a flaky sleep-and-hope.
func TestAwaitCompletionActorRejectGraceReturnsUsage(t *testing.T) {
	old := providerTerminalGrace
	providerTerminalGrace = 200 * time.Millisecond
	defer func() { providerTerminalGrace = old }()

	srv, _, _ := billingTestServer(t)
	prov := srv.registry.Register("prov-await", nil, &protocol.RegisterMessage{})
	pr := &registry.PendingRequest{
		RequestID:  "await-reject",
		ProviderID: prov.ID,
		ChunkCh:    make(chan string, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	bindWonProviderTerminal(t, srv, prov, pr, terminalComplete)

	// handleComplete's channel tail, delayed so it can only land in the inner
	// grace select, not the outer one.
	go func() {
		time.Sleep(20 * time.Millisecond)
		pr.CompleteCh <- protocol.UsageInfo{CompletionTokens: 9}
	}()

	usage, outcome := srv.awaitCompletion(firedDeadlineCtx(t), pr)
	if outcome != completionUsage {
		t.Fatalf("outcome = %v, want completionUsage (deadline must defer to the won terminal)", outcome)
	}
	if usage.CompletionTokens != 9 {
		t.Fatalf("usage = %+v, want the real completion usage", usage)
	}
}

// TestAwaitCompletionNoActorReportsTimeout confirms the legacy path is preserved:
// with no actor bound, a fired deadline still reports a timeout immediately (no
// added latency, no grace).
func TestAwaitCompletionNoActorReportsTimeout(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	pr := &registry.PendingRequest{
		RequestID:  "await-noactor",
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	if _, outcome := srv.awaitCompletion(firedDeadlineCtx(t), pr); outcome != completionTimeout {
		t.Fatalf("outcome = %v, want completionTimeout for an attempt with no bound actor", outcome)
	}
}

// TestDrainNonStreamingTerminalDeliversWonCompletion drives the outer-loop grace
// helper directly with a fired deadline and a won completion terminal: it must
// finalize the real 200 response, not fall through to a timeout, and must not
// refund.
func TestDrainNonStreamingTerminalDeliversWonCompletion(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	prov := srv.registry.Register("prov-drain-ok", nil, &protocol.RegisterMessage{})
	pr := &registry.PendingRequest{
		RequestID:        "drain-ok",
		Model:            "m",
		ProviderID:       prov.ID,
		ConsumerKey:      testConsumerID,
		ReservedMicroUSD: 10_000,
		ChunkCh:          make(chan string, 2),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	bindWonProviderTerminal(t, srv, prov, pr, terminalComplete)

	// handleComplete's channel tail: usage buffered, then ChunkCh closed.
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 2, CompletionTokens: 5}
	close(pr.ChunkCh)
	close(pr.CompleteCh)

	chunks := []string{`data: {"object":"chat.completion","choices":[{"message":{"role":"assistant","content":"hi"}}]}`}
	rr := httptest.NewRecorder()
	if !srv.drainNonStreamingTerminal(rr, pr, firedDeadlineCtx(t), &chunks) {
		t.Fatal("drain must report it produced a terminal response")
	}
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"content":"hi"`) {
		t.Fatalf("real completion not delivered: %s", rr.Body.String())
	}
	if pr.IsReservationFinalized() {
		t.Fatal("success path must not refund the reservation")
	}
}

// TestDrainNonStreamingTerminalDeliversWonProviderError proves the drain path
// also delivers a real provider ERROR terminal (the error is buffered on ErrorCh
// and surfaced by finalizeNonStreamingResponse's non-blocking check after the
// ChunkCh close) rather than a spurious timeout.
func TestDrainNonStreamingTerminalDeliversWonProviderError(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	prov := srv.registry.Register("prov-drain-err", nil, &protocol.RegisterMessage{})
	pr := &registry.PendingRequest{
		RequestID:        "drain-err",
		Model:            "m",
		ProviderID:       prov.ID,
		ConsumerKey:      testConsumerID,
		ReservedMicroUSD: 5_000,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	bindWonProviderTerminal(t, srv, prov, pr, terminalError)

	// handleInferenceError's channel tail: error buffered, then channels closed.
	pr.ErrorCh <- protocol.InferenceErrorMessage{RequestID: "drain-err", Error: "boom", StatusCode: http.StatusBadGateway, ErrorReason: "provider_error"}
	close(pr.ChunkCh)
	close(pr.CompleteCh)
	close(pr.ErrorCh)

	chunks := []string(nil)
	rr := httptest.NewRecorder()
	if !srv.drainNonStreamingTerminal(rr, pr, firedDeadlineCtx(t), &chunks) {
		t.Fatal("drain must produce the real provider error response")
	}
	if rr.Code == http.StatusGatewayTimeout {
		t.Fatalf("client got a spurious timeout instead of the provider error; body = %s", rr.Body.String())
	}
	if rr.Code != http.StatusBadGateway || !strings.Contains(rr.Body.String(), "boom") {
		t.Fatalf("provider error not delivered: status=%d body=%s", rr.Code, rr.Body.String())
	}
}

// TestDrainNonStreamingTerminalGraceExpiryFallsThrough verifies the bounded
// quiescence invariant: if the won terminal never actually delivers on the
// channels (billing hung past the grace), the drain returns false within the
// grace so the caller falls through to its refund + timeout — it never hangs.
func TestDrainNonStreamingTerminalGraceExpiryFallsThrough(t *testing.T) {
	old := providerTerminalGrace
	providerTerminalGrace = 15 * time.Millisecond
	defer func() { providerTerminalGrace = old }()

	srv, _, _ := billingTestServer(t)
	prov := srv.registry.Register("prov-drain-grace", nil, &protocol.RegisterMessage{})
	pr := &registry.PendingRequest{
		RequestID:  "drain-grace",
		Model:      "m",
		ProviderID: prov.ID,
		ChunkCh:    make(chan string, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	// Terminal claimed, but the channels NEVER deliver (ChunkCh stays open).
	bindWonProviderTerminal(t, srv, prov, pr, terminalComplete)

	chunks := []string{"data: partial"}
	rr := httptest.NewRecorder()
	start := time.Now()
	if srv.drainNonStreamingTerminal(rr, pr, firedDeadlineCtx(t), &chunks) {
		t.Fatal("drain must return false when the grace expires with no terminal delivered")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("drain must be bounded by the grace; took %v", elapsed)
	}
}
