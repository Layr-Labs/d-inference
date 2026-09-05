package api

// queue_deadline (routing-v2 P4): a request whose request-absolute
// first-content clock expires while it is still waiting in the coordinator
// queue was reported as first_chunk_timeout — indistinguishable in the
// rejection ledger from a dispatched provider that went silent. It now carries
// its own reason code, with the same retryable 429 + Retry-After.

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
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
	res := chatRequestWithID(ctx, ts.URL, model, "queue-deadline-live")
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
	if !strings.Contains(res.body, "rate_limit_exceeded") || !strings.Contains(res.body, errQueueDeadlineExpired) {
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
	if rec.ReasonCode != rejectionReasonQueueDeadline {
		t.Fatalf("rejection ReasonCode = %q, want %q", rec.ReasonCode, rejectionReasonQueueDeadline)
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
	srv, _ := testServer(t)
	newState := func() *dispatchState {
		return &dispatchState{s: srv, model: "m", excludeProviders: map[string]struct{}{}}
	}

	d := newState()
	d.setLastError(errQueueDeadlineExpired, http.StatusGatewayTimeout)
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

	// A sticky genuine fault from an earlier attempt outranks the queue's
	// terminal: its own text, its own status.
	d = newState()
	fault := dispatchTerminalFailure{errText: "boom", statusCode: http.StatusBadGateway}
	d.genuineFault = &fault
	d.setLastError(errQueueDeadlineExpired, http.StatusGatewayTimeout)
	failure, sticky = d.terminalFailureForExhaustion()
	code, reason, reclassified, dominance = d.resolveDominantExhaustedStatus(failure, sticky)
	if !sticky || code != http.StatusBadGateway || reason != "dispatch_exhausted" || reclassified || dominance != exhaustedGenuineFault {
		t.Fatalf("sticky fault = (%d, %q, %v, %d), want (502, dispatch_exhausted, false, genuine fault)", code, reason, reclassified, dominance)
	}
}

// queuedFleetHarness boots a coordinator with one REAL WebSocket provider whose
// heartbeat reports a saturated token budget, so every request for model
// capacity-spills to the coordinator queue (queue-before-shed on, cold dispatch
// off). Returns the server, store, registry and test server.
func queuedFleetHarness(t *testing.T, ctx context.Context, cfg ServerConfig, model string) (*Server, *store.MemoryStore, *registry.Registry, *httptest.Server) {
	t.Helper()
	return queuedFleetHarnessConfigured(t, ctx, cfg, model, nil)
}

// queuedFleetHarnessConfigured is queuedFleetHarness with a hook that runs on
// the server BEFORE the HTTP listener starts and any provider connects. Wiring
// that provider goroutines read (the Datadog client, emitters) must go through
// it: setting those fields after connectProvider races the heartbeat path.
func queuedFleetHarnessConfigured(t *testing.T, ctx context.Context, cfg ServerConfig, model string, configure func(*Server)) (*Server, *store.MemoryStore, *registry.Registry, *httptest.Server) {
	t.Helper()
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, cfg, logger)
	srv.challengeInterval = time.Hour
	if configure != nil {
		configure(srv)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: model, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "done") })
	p := markOnlyProviderRoutable(t, reg)
	writeAdaptiveHeartbeat(t, ctx, conn, model, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
			State:                 "running",
			MaxConcurrency:        1,
			ActiveTokenBudgetUsed: 950,
			ActiveTokenBudgetMax:  1_000,
		}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil && p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 950
	})
	return srv, st, reg, ts
}

type chatResult struct {
	status     int
	body       string
	retryAfter string
	err        error
}

func chatRequestWithID(ctx context.Context, baseURL, model, requestID string) chatResult {
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":64}`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		return chatResult{err: err}
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	if requestID != "" {
		req.Header.Set("X-Request-ID", requestID)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return chatResult{err: err}
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return chatResult{status: resp.StatusCode, body: string(data), retryAfter: resp.Header.Get("Retry-After")}
}
