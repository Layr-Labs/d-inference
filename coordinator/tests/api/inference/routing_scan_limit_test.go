package inference_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRoutingScanSemaphore_AcquireTimeoutShedsCapacityShaped429(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetRoutingConcurrency(2)
	// Occupy both slots for the whole test.
	srv.scanGate.Acquire(0, nil)
	srv.scanGate.Acquire(0, nil)
	defer func() { srv.scanGate.Release(); srv.scanGate.Release() }()

	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	deadline := 120 * time.Millisecond
	session := srv.NewDispatchSession(inference.DispatchRequest{
		Writer: w, Request: r, Model: "saturated-model", PublicModel: "saturated-model",
		Body: []byte(`{"model":"saturated-model"}`), ConsumerKey: "test-key",
		EstimatedPromptTokens: 6, RequestedMaxTokens: 64,
		Timing: &registry.RequestTiming{ReceivedAt: time.Now()}, Deadline: deadline,
		SpeculativeAt: deadline / 2, RefundReservation: func() {},
	})

	start := time.Now()
	result := session.Run(r.Context())
	elapsed := time.Since(start)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (capacity-shaped shed, NOT the 503 a scan would produce); body=%s",
			w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "rate_limit_exceeded") {
		t.Errorf("body missing rate_limit_exceeded code; body=%s", w.Body.String())
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("missing Retry-After header on the 429")
	}
	if !result.Terminal.Unservable || result.Terminal.UnservableReason != "routing_saturated" {
		t.Errorf("verdict = (unservable=%v, reason=%q), want (true, %q)",
			result.Terminal.Unservable, result.Terminal.UnservableReason, "routing_saturated")
	}
	if result.LastAttempt != 0 {
		t.Errorf("attempts = %d, want the shed to terminate the ladder at attempt 0", result.LastAttempt+1)
	}
	// The goroutine parked for the remaining budget, and never longer.
	if elapsed < 80*time.Millisecond || elapsed > 3*time.Second {
		t.Errorf("shed after %s, want ~the 120ms remaining budget", elapsed)
	}
}

func TestRoutingScanSemaphore_ClientGoneTakesClientGonePath(t *testing.T) {
	srv, st := testServer(t)
	srv.SetRoutingConcurrency(2)
	srv.scanGate.Acquire(0, nil)
	srv.scanGate.Acquire(0, nil)
	defer func() { srv.scanGate.Release(); srv.scanGate.Release() }()

	ctx, cancel := context.WithCancel(context.Background())
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}")).WithContext(ctx)
	refunds := 0
	deadline := 5 * time.Second // far beyond the cancel point: the timeout arm must not win
	session := srv.NewDispatchSession(inference.DispatchRequest{
		Writer: w, Request: r, Model: "client-gone-model", PublicModel: "client-gone-model",
		Body: []byte(`{"model":"client-gone-model"}`), ConsumerKey: "test-key",
		EstimatedPromptTokens: 6, RequestedMaxTokens: 64,
		Timing: &registry.RequestTiming{ReceivedAt: time.Now()}, Deadline: deadline,
		SpeculativeAt: deadline / 2, RefundReservation: func() { refunds++ },
	})

	go func() {
		time.Sleep(40 * time.Millisecond)
		cancel()
	}()
	result := session.Run(r.Context())

	if w.Body.Len() != 0 {
		t.Fatalf("client-gone wrote a response body: %s", w.Body.String())
	}
	if w.Header().Get("Retry-After") != "" {
		t.Error("client-gone must not carry a Retry-After header")
	}
	if result.Terminal.Unservable {
		t.Errorf("client-gone latched unservable(%q) — that is the saturation verdict", result.Terminal.UnservableReason)
	}
	if refunds != 1 {
		t.Errorf("reservation refunds = %d, want exactly 1", refunds)
	}
	if got := len(st.RejectionRecordsSince(time.Time{})); got != 0 {
		t.Errorf("rejection-ledger rows = %d, want 0 for a client-gone", got)
	}
}
