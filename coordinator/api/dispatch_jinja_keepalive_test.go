package api

// PR #548 review follow-up (Codex P2, dispatch.go ~2424): when the prefill
// keepalive has already committed HTTP 200 (long prefill / cold load before a
// template-render failure), the exhausted ladder's keepaliveCommitted branch
// returned BEFORE the terminalClientErrorMessage handling — so a latched
// jinja_* terminal streamed out as a provider_error SSE event carrying the
// provider's RAW template backtrace instead of the curated
// invalid_request_error / model_capability body the status-coded path
// returns. These tests drive the real dispatch ladder over the fake-provider
// WS harness with keepalives enabled.

import (
	"context"
	"encoding/json"
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

// setupKeepaliveFailoverServer mirrors setupFailoverServer with the prefill
// SSE keepalive enabled at a test-fast cadence, so a script that stalls a few
// intervals before erroring deterministically commits HTTP 200 first.
func setupKeepaliveFailoverServer(t *testing.T, interval time.Duration) (*registry.Registry, *store.MemoryStore, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 500 * time.Millisecond
	srv.SetPrefillKeepaliveInterval(interval)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return reg, st, ts
}

// sendInferenceErrorWithReason mirrors sendInferenceError but carries the
// structured error_reason a 0.7.11+ provider stamps on the wire (the E4/E5
// vocabulary the coordinator's terminal classification keys on).
func (fp *failoverProvider) sendInferenceErrorWithReason(ctx context.Context, req protocol.InferenceRequestMessage, errMsg string, statusCode int, errReason string) {
	msg := protocol.InferenceErrorMessage{
		Type:        protocol.TypeInferenceError,
		RequestID:   req.RequestID,
		Error:       errMsg,
		StatusCode:  statusCode,
		ErrorReason: errReason,
	}
	data, _ := json.Marshal(msg)
	if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
		fp.t.Logf("provider %s: write inference_error: %v", fp.name, err)
	}
}

// postSSE posts a streaming request to path and drains the full response —
// like postChat, but for an arbitrary endpoint (/v1/responses too).
func postSSE(ctx context.Context, tsURL, path, apiKey, body string) (int, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tsURL+path, strings.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(respBody), nil
}

// rawJinjaBacktrace is the provider-side template error text that must NEVER
// reach the consumer once the terminal classification has latched.
const rawJinjaBacktrace = "Runtime error: upper filter requires string"

// keepaliveJinjaScript stalls past several keepalive intervals (so the SSE 200
// deterministically commits) and then rejects with a jinja_* 500.
func keepaliveJinjaScript(stall time.Duration) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		time.Sleep(stall)
		fp.sendInferenceErrorWithReason(ctx, req, rawJinjaBacktrace, http.StatusInternalServerError, "jinja_template")
	}
}

// A latched jinja terminal AFTER the keepalive committed HTTP 200 must stream
// the curated invalid_request_error / model_capability body in-band — not a
// provider_error event wrapping the raw template backtrace. Fails without the
// keepaliveCommitted curated-error branch in the exhausted ladder.
func TestJinjaTerminal_AfterKeepaliveCommit_CuratedInBandError(t *testing.T) {
	reg, _, ts := setupKeepaliveFailoverServer(t, 25*time.Millisecond)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "jinja-keepalive-model"
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}},
		Script: keepaliveJinjaScript(300 * time.Millisecond),
	})

	status, body, err := postSSE(ctx, ts.URL, "/v1/chat/completions", "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200 (keepalive already committed); body = %s", status, body)
	}
	if !strings.Contains(body, ": keepalive") {
		t.Fatalf("no keepalive comment in stream — the test did not exercise the committed path; body = %s", body)
	}
	if !strings.Contains(body, jinjaTerminalRejectMessage) {
		t.Errorf("in-band error is missing the curated model_capability message; body = %s", body)
	}
	if !strings.Contains(body, `"invalid_request_error"`) {
		t.Errorf("in-band error type = want invalid_request_error; body = %s", body)
	}
	if !strings.Contains(body, `"model_capability"`) {
		t.Errorf("in-band error code = want model_capability; body = %s", body)
	}
	if strings.Contains(body, rawJinjaBacktrace) {
		t.Errorf("raw provider template backtrace leaked to the consumer; body = %s", body)
	}
	if strings.Contains(body, `"provider_error"`) {
		t.Errorf("latched jinja terminal surfaced as provider_error; body = %s", body)
	}
	if n := strings.Count(body, "data: [DONE]"); n != 1 {
		t.Errorf("stream has %d [DONE] terminators, want exactly 1; body = %s", n, body)
	}
}

// Same latch on a /v1/responses stream: the Responses error shape
// (event: error, no [DONE]) must carry the curated message with type
// invalid_request_error instead of provider_error + raw backtrace.
func TestJinjaTerminal_AfterKeepaliveCommit_ResponsesShape(t *testing.T) {
	reg, _, ts := setupKeepaliveFailoverServer(t, 25*time.Millisecond)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "jinja-keepalive-responses-model"
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}},
		Script: keepaliveJinjaScript(300 * time.Millisecond),
	})

	reqBody, err := json.Marshal(map[string]any{
		"model": model, "input": "keepalive responses test prompt",
		"stream": true, "max_output_tokens": 64,
	})
	if err != nil {
		t.Fatalf("marshal responses body: %v", err)
	}
	status, body, err := postSSE(ctx, ts.URL, "/v1/responses", "test-key", string(reqBody))
	if err != nil {
		t.Fatalf("responses request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200 (keepalive already committed); body = %s", status, body)
	}
	if !strings.Contains(body, ": keepalive") {
		t.Fatalf("no keepalive comment in stream — the test did not exercise the committed path; body = %s", body)
	}
	if !strings.Contains(body, "event: error") {
		t.Errorf("responses stream missing the event: error terminal; body = %s", body)
	}
	if !strings.Contains(body, jinjaTerminalRejectMessage) {
		t.Errorf("in-band error is missing the curated model_capability message; body = %s", body)
	}
	if !strings.Contains(body, `"invalid_request_error"`) {
		t.Errorf("in-band error type = want invalid_request_error; body = %s", body)
	}
	if strings.Contains(body, rawJinjaBacktrace) {
		t.Errorf("raw provider template backtrace leaked to the consumer; body = %s", body)
	}
	if strings.Contains(body, `"provider_error"`) {
		t.Errorf("latched jinja terminal surfaced as provider_error; body = %s", body)
	}
	if strings.Contains(body, "data: [DONE]") {
		t.Errorf("responses error shape must not emit [DONE]; body = %s", body)
	}
}

// Control (non-latched behavior preserved): with the jinja kill switch OFF,
// nothing latches, so the keepalive-committed request keeps the legacy
// transparent-failover behavior — the second provider serves and no in-band
// error event reaches the consumer. Guards the new branch's condition (it must
// fire ONLY when a curated terminal message is latched).
func TestJinjaKillSwitch_AfterKeepaliveCommit_TransparentFailover(t *testing.T) {
	t.Setenv(envJinjaTerminalReject, "false")
	reg, _, ts := setupKeepaliveFailoverServer(t, 25*time.Millisecond)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "jinja-keepalive-killswitch-model"
	rec := &dispatchRecorder{}
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		if rec.record(fp.name) == 1 {
			time.Sleep(300 * time.Millisecond) // let the keepalive commit HTTP 200
			fp.sendInferenceErrorWithReason(ctx, req, rawJinjaBacktrace, http.StatusInternalServerError, "jinja_template")
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.20", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	status, body, err := postSSE(ctx, ts.URL, "/v1/chat/completions", "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if !strings.Contains(body, ": keepalive") {
		t.Fatalf("no keepalive comment in stream — the test did not exercise the committed path; body = %s", body)
	}
	seq := rec.sequence()
	if len(seq) != 2 {
		t.Fatalf("dispatch sequence = %v, want 2 (kill switch off → legacy failover); status=%d body=%s", seq, status, body)
	}
	assertCleanFailoverStream(t, status, body, markerFor(seq[1]))
}
