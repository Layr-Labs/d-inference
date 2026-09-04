package api

// Send-failed ladder cap regression tests.
//
// A provider write failure (writer stopped — closed by the write watchdog or
// a read error — or a full 128-deep data lane) used to surface as the untyped
// string "failed to send request to provider": dispatchPrimary treated it as
// a plain outcomeRetry with no cap (shouldStopFailover never sees it), so a
// cascade of dead writers walked up to maxDispatchAttempts=64 distinct
// providers, one routingScanSem-gated reservation scan each, and at exhaustion
// the client got a raw 502 (OpenRouter provider_5xx) although no provider
// ever ran the request (45-55K/h in the 2026-08-31 cascade). The class is now
// bounded at maxCapacityClassRetries and resolves to one uptime-neutral 429
// with its own closed reason, provider_unreachable.
//
// Fault injection is at the writer, as reviewed: a provider registered with
// no socket has a nil writer (WriteTextDeferred fails with
// ErrProviderWriterStopped while the provider stays registered and routable —
// the exact shape of a watchdog-closed writer whose read loop has not yet
// unwound), and a live socket nobody reads lets the data lane fill to
// ErrProviderWriterQueueFull.

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func newSendFailedDispatch(srv *Server, model string, stream bool) (*dispatchState, *httptest.ResponseRecorder) {
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	deadline := 2 * time.Second
	return &dispatchState{
		s:                     srv,
		w:                     w,
		r:                     r,
		model:                 model,
		publicModel:           model,
		stream:                stream,
		rawBody:               []byte(`{"model":"` + model + `","messages":[{"role":"user","content":"hi"}]}`),
		consumerKey:           "test-key",
		estimatedPromptTokens: 6,
		requestedMaxTokens:    64,
		timing:                &registry.RequestTiming{},
		deadline:              deadline,
		speculativeAt:         10 * deadline,
		refundReservation:     func() {},
		excludeProviders:      map[string]struct{}{},
	}, w
}

// TestDispatch_SendFailedLadder_CapsAtThreeAttempts: five registered,
// routable providers whose writers are dead. The ladder must stop after
// maxCapacityClassRetries send failures (each on a distinct provider) and
// answer one retryable 429 with reason provider_unreachable — not walk all
// five and return a raw 502 — and none of the providers is struck.
func TestDispatch_SendFailedLadder_CapsAtThreeAttempts(t *testing.T) {
	reg, st, srv, _ := setupTTFTFailoverServer(t)
	collector, dd := attachTestDD(t, srv)
	const model = "send-failed-ladder-model"
	const fleet = 5
	var ids []string
	for i := 0; i < fleet; i++ {
		p := makeRoutableProvider(t, reg, fmt.Sprintf("dead-writer-%d", i), model)
		ids = append(ids, p.ID)
	}
	since := time.Now()

	d, w := newSendFailedDispatch(srv, model, false)
	start := time.Now()
	d.run()
	elapsed := time.Since(start)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (send-failed ladder → uptime-neutral 429); body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "rate_limit_exceeded") {
		t.Errorf("body missing rate_limit_exceeded code; body=%s", w.Body.String())
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("missing Retry-After header on the 429")
	}
	if d.sendFailedRetries != maxCapacityClassRetries {
		t.Errorf("sendFailedRetries = %d, want %d — the ladder must stop at the cap, not walk all %d providers",
			d.sendFailedRetries, maxCapacityClassRetries, fleet)
	}
	if d.unservableReason != rejectionReasonProviderUnreachable {
		t.Errorf("unservableReason = %q, want %q", d.unservableReason, rejectionReasonProviderUnreachable)
	}
	if elapsed > 3*time.Second {
		t.Errorf("dispatch took %s — the capped ladder must return promptly", elapsed)
	}
	packets := dd.packets(collector)
	sendFailed := requireMetricWithTags(t, packets, "routing.dispatch_to_capacity_503", "reason:send_failed", "kind:writer_stopped", "model:"+model)
	// The DogStatsD client aggregates identical counters into one packet.
	var sendFailedTotal float64
	for _, pk := range sendFailed {
		sendFailedTotal += metricValue(t, pk)
	}
	if int(sendFailedTotal) != maxCapacityClassRetries {
		t.Errorf("dispatch_to_capacity_503{reason:send_failed} total = %v, want %d (one per attempt)", sendFailedTotal, maxCapacityClassRetries)
	}
	requireMetricWithTags(t, packets, "routing.provider_unreachable_rejected", "model:"+model, "stage:dispatch")
	if got := findMetrics(packets, "routing.oversized_request_rejected"); len(got) != 0 {
		t.Errorf("an unreachable verdict must never use the oversized vocabulary: %v", got)
	}
	for _, id := range ids {
		if reg.ProviderBreakerOpen(id) {
			t.Errorf("provider %s: node breaker opened by a coordinator-side send failure", id)
		}
		if reg.InferenceErrorCooldownActive(id, model, "base") {
			t.Errorf("provider %s: inference-error cooldown struck by a coordinator-side send failure", id)
		}
		if p := reg.GetProvider(id); p == nil {
			t.Errorf("provider %s was removed from the registry", id)
		}
	}
	var ledger []string
	for _, rec := range st.RejectionRecordsSince(since) {
		ledger = append(ledger, rec.Stage+"/"+rec.ReasonCode)
		if rec.Stage == "dispatch" && rec.ReasonCode != rejectionReasonProviderUnreachable {
			t.Errorf("dispatch rejection row reason = %q, want %q", rec.ReasonCode, rejectionReasonProviderUnreachable)
		}
		if rec.Stage == "dispatch" && rec.HTTPStatus != http.StatusTooManyRequests {
			t.Errorf("dispatch rejection row status = %d, want 429", rec.HTTPStatus)
		}
	}
	if len(ledger) == 0 {
		t.Error("no rejection-ledger row was written for the exhausted request")
	}
}

// TestDispatch_SendFailedThenLiveProviderServes: one dead writer (preferred
// by the cost function: higher decode TPS) and one live provider. The send
// failure costs one attempt, the live provider serves, and nothing about the
// request is rejected.
func TestDispatch_SendFailedThenLiveProviderServes(t *testing.T) {
	reg, _, srv, ts := setupTTFTFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	const model = "send-failed-failover-model"
	makeRoutableProvider(t, reg, "dead-writer", model) // DecodeTPS 90: tried first
	live := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "live", Version: "0.9.0", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	d, w := newSendFailedDispatch(srv, model, true)
	d.run()

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (served on the live provider); body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), markerFor("live")) {
		t.Errorf("response does not carry the live provider's content; body=%s", w.Body.String())
	}
	if got := live.dispatchCount(); got != 1 {
		t.Errorf("live provider dispatches = %d, want 1", got)
	}
	if d.sendFailedRetries != 1 {
		t.Errorf("sendFailedRetries = %d, want 1 (the dead writer was tried first)", d.sendFailedRetries)
	}
	if d.unservable {
		t.Error("a served request must not be latched unservable")
	}
}

// TestDispatch_SendFailedQueueFullDoesNotMarkProviderOffline: a provider
// whose data lane is full (alive socket, nobody reading, 128 frames queued
// behind a blocked write) rejects the frame with ErrProviderWriterQueueFull.
// Below the cap the exhausted ladder still resolves the class to a 429 with
// reason provider_unreachable — never a raw 5xx — and the provider is neither
// marked offline nor removed: it is alive, merely excluded for this request.
func TestDispatch_SendFailedQueueFullDoesNotMarkProviderOffline(t *testing.T) {
	reg, _, srv, _ := setupTTFTFailoverServer(t)
	collector, dd := attachTestDD(t, srv)
	const model = "send-failed-queue-full-model"
	serverConn, _ := testWebSocketPairAPI(t) // the client never reads
	jammed := makeRoutableProviderConn(t, reg, "jammed", model, serverConn)
	t.Cleanup(func() { reg.Disconnect(jammed.ID) })

	// Fill the data lane: once the loopback buffers are full a frame blocks
	// in the kernel (for the 5 s write watchdog) and the next 128 queue up
	// behind it, so the dispatch's own frame is refused at submit.
	frame := bytes.Repeat([]byte("x"), 1<<20)
	for i := 0; i < 132; i++ {
		go func() { _ = jammed.WriteText(context.Background(), frame) }()
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		st := jammed.LinkStats()
		if st.DataQueueDepth >= 128 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("data lane never filled: %+v", st)
		}
		time.Sleep(5 * time.Millisecond)
	}

	d, w := newSendFailedDispatch(srv, model, false)
	d.run()

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body=%s", w.Code, w.Body.String())
	}
	if d.sendFailedRetries != 1 {
		t.Errorf("sendFailedRetries = %d, want 1", d.sendFailedRetries)
	}
	if d.unservable {
		t.Error("below the cap the request must not be latched unservable (the exhausted ladder classifies it)")
	}
	packets := dd.packets(collector)
	requireMetricWithTags(t, packets, "routing.dispatch_to_capacity_503", "reason:send_failed", "kind:queue_full")
	requireMetricWithTags(t, packets, "routing.provider_unreachable_rejected", "model:"+model)
	p := reg.GetProvider(jammed.ID)
	if p == nil {
		t.Fatal("a provider with a full data lane was removed from the registry")
	}
	p.Mu().Lock()
	status := p.Status
	p.Mu().Unlock()
	if status != registry.StatusOnline {
		t.Errorf("provider status = %q after a queue-full send failure, want online (alive, merely excluded for this request)", status)
	}
}
