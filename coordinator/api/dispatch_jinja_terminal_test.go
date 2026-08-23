package api

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

// E4 (2026-07-15 platform errors deep dive): a provider error_reason of
// jinja_channel_tags / jinja_null_bridge / jinja_template is a DETERMINISTIC
// template-render failure (the same body renders identically on every
// provider). The dispatch ladder must stop on the FIRST occurrence and latch
// a single 422 model_capability rejection — instead of failing over
// fleet-wide (prod: 1.57 dispatch rows per jinja request, observed up to 17)
// — and the provider must take no reputation hit for it.

func TestShouldStopFailover_JinjaReasonsStopWith422(t *testing.T) {
	for _, reason := range []string{"jinja_template", "jinja_channel_tags", "jinja_null_bridge"} {
		d := &dispatchState{
			s: newTestServerForDispatch(t), model: "m",
			lastErrCode:   500,
			lastErr:       "Runtime error: upper filter requires string",
			lastErrReason: reason,
		}
		if !d.shouldStopFailover() {
			t.Fatalf("%s: a jinja provider rejection must stop failover on the first attempt", reason)
		}
		if !d.terminalClientError {
			t.Fatalf("%s: jinja stop must latch terminalClientError", reason)
		}
		if d.terminalClientErrorCode != http.StatusUnprocessableEntity {
			t.Fatalf("%s: latched code = %d, want 422 (our classification, not the provider's raw 500)", reason, d.terminalClientErrorCode)
		}
		if d.terminalClientErrorReason != rejectionReasonTemplateRenderFailed {
			t.Fatalf("%s: ledger reason = %q, want %q", reason, d.terminalClientErrorReason, rejectionReasonTemplateRenderFailed)
		}
		if d.terminalClientErrorMessage != jinjaTerminalRejectMessage {
			t.Fatalf("%s: surfaced message = %q, want the curated model_capability text", reason, d.terminalClientErrorMessage)
		}
	}
}

// A plain provider 500 with no jinja reason must keep failing over exactly as
// before — the stop keys on the normalized REASON, never on the 500 status.
func TestShouldStopFailover_NonJinja500StillFailsOver(t *testing.T) {
	for _, reason := range []string{"", "provider_error", "model_load"} {
		d := &dispatchState{
			s: newTestServerForDispatch(t), model: "m",
			lastErrCode: 500, lastErr: "boom", lastErrReason: reason,
		}
		if d.shouldStopFailover() {
			t.Fatalf("reason %q: a non-jinja 500 must fail over, not stop", reason)
		}
		if d.terminalClientError {
			t.Fatalf("reason %q: must not latch terminalClientError", reason)
		}
	}
}

// Provider-cased / dashed variants normalize before matching (the wire value
// is produced by a different codebase and must not bypass the stop on casing).
func TestShouldStopFailover_JinjaReasonNormalizes(t *testing.T) {
	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode: 500, lastErrReason: " Jinja-Template ",
	}
	if !d.shouldStopFailover() {
		t.Fatal("a cased/dashed jinja reason must still stop failover")
	}
	if d.terminalClientErrorCode != http.StatusUnprocessableEntity {
		t.Fatalf("latched code = %d, want 422", d.terminalClientErrorCode)
	}
}

// Kill switch: EIGENINFERENCE_JINJA_TERMINAL_REJECT=false restores the legacy
// fail-over-on-500 behavior (and must not latch anything).
func TestShouldStopFailover_JinjaKillSwitch(t *testing.T) {
	t.Setenv(envJinjaTerminalReject, "false")
	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode: 500, lastErrReason: "jinja_template",
	}
	if d.shouldStopFailover() {
		t.Fatal("with the kill switch off, a jinja 500 must fall back to legacy failover")
	}
	if d.terminalClientError {
		t.Fatal("kill switch must not latch terminalClientError")
	}
}

// A jinja rejection observed from a speculative race LOSER (whose error is
// never written to d.lastErr) must latch via latchDeterministicLoser so the
// survivor's later transient error cannot resume the storm.
func TestLatchDeterministicLoser_JinjaReason(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{
		StatusCode:  500,
		Error:       "Runtime error: upper filter requires string",
		ErrorReason: "jinja_template",
	})
	if !d.terminalClientError || d.terminalClientErrorCode != http.StatusUnprocessableEntity {
		t.Fatalf("race-loser jinja must latch 422; got latched=%v code=%d", d.terminalClientError, d.terminalClientErrorCode)
	}
	if d.terminalClientErrorReason != rejectionReasonTemplateRenderFailed {
		t.Fatalf("ledger reason = %q, want %q", d.terminalClientErrorReason, rejectionReasonTemplateRenderFailed)
	}
	// Survivor reports a transient error that alone would NOT stop failover.
	d.lastErrCode = 0
	d.lastErr = "request rejected: queue full"
	if !d.shouldStopFailover() {
		t.Fatal("a latched race-loser jinja rejection must stop failover regardless of the survivor's error")
	}
}

// The race-loser mirror honors the kill switch too.
func TestLatchDeterministicLoser_JinjaKillSwitch(t *testing.T) {
	t.Setenv(envJinjaTerminalReject, "false")
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{
		StatusCode: 500, ErrorReason: "jinja_template",
	})
	if d.terminalClientError {
		t.Fatal("kill switch must disable the race-loser jinja latch")
	}
}

// Route-outcome taxonomy: a jinja failure is recorded as class client_error
// WITHOUT AdmittedButFailed (not an admission mismatch, not a provider
// fault), while the row's ErrorReason PRESERVES the jinja_* value so the
// inference.error{reason:jinja_*} series keeps measuring real render
// failures.
func TestJinjaRouteOutcome_ClientErrorClassPreservesReason(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	out := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		StatusCode:  500,
		Error:       "Runtime error: upper filter requires string",
		ErrorReason: "jinja_template",
	})
	if out.ErrorClass != errorClassClientError {
		t.Fatalf("class = %q, want %q", out.ErrorClass, errorClassClientError)
	}
	if out.AdmittedButFailed {
		t.Fatal("a jinja render failure must NOT set AdmittedButFailed")
	}
	if out.ErrorReason != errorReasonJinjaTemplate {
		t.Fatalf("reason = %q, want %q preserved on the row", out.ErrorReason, errorReasonJinjaTemplate)
	}

	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode: 500, lastErr: "upper filter requires string", lastErrReason: "jinja_template",
	}
	dout := d.providerFailedRoutingOutcome()
	if dout.ErrorClass != errorClassClientError || dout.AdmittedButFailed {
		t.Fatalf("providerFailedRoutingOutcome for jinja: class=%q admitted=%v, want client_error + not admitted", dout.ErrorClass, dout.AdmittedButFailed)
	}
	if dout.ErrorReason != errorReasonJinjaTemplate {
		t.Fatalf("providerFailedRoutingOutcome reason = %q, want %q", dout.ErrorReason, errorReasonJinjaTemplate)
	}
}

// isJinjaTemplateErrorReason is the single normalization point shared by the
// dispatch stop, the reputation exemption, and the outcome taxonomy.
func TestIsJinjaTemplateErrorReason(t *testing.T) {
	for reason, want := range map[string]bool{
		"jinja_template":     true,
		"jinja_channel_tags": true,
		"jinja_null_bridge":  true,
		"Jinja-Template":     true,
		" jinja_template ":   true,
		"":                   false,
		"provider_error":     false,
		"model_load":         false,
		"tool_noncompliance": false,
		"jinja":              false,
	} {
		if got := isJinjaTemplateErrorReason(reason); got != want {
			t.Errorf("isJinjaTemplateErrorReason(%q) = %v, want %v", reason, got, want)
		}
	}
}

// handleInferenceError must NOT record a reputation failure for a jinja_*
// terminal — the request shape, not the provider, is at fault. Capacity and
// cancel exemptions stay unchanged, and a plain 500 still counts.
func TestHandleInferenceError_JinjaSkipsRecordJobFailure(t *testing.T) {
	cases := []struct {
		name        string
		msg         protocol.InferenceErrorMessage
		wantFailure bool
	}{
		{
			name: "typed jinja_template is exempt",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "Runtime error: upper filter requires string",
				ErrorReason: "jinja_template", FailureCode: protocol.FailureCodeTemplateRender,
			},
			wantFailure: false,
		},
		{
			name: "typed jinja_channel_tags is exempt",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "template raised", ErrorReason: "jinja_channel_tags", FailureCode: protocol.FailureCodeTemplateRender,
			},
			wantFailure: false,
		},
		{
			name: "typed jinja_null_bridge is exempt",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "Cannot convert value", ErrorReason: "jinja_null_bridge", FailureCode: protocol.FailureCodeTemplateRender,
			},
			wantFailure: false,
		},
		{
			name:        "plain 500 still records a failure",
			msg:         protocol.InferenceErrorMessage{StatusCode: 500, Error: "boom", FailureCode: protocol.FailureCodeGenerationFailure},
			wantFailure: true,
		},
		{
			name:        "capacity 503 stays exempt",
			msg:         protocol.InferenceErrorMessage{StatusCode: 503, Error: "token_budget_exhausted: full", FailureCode: protocol.FailureCodeCapacity},
			wantFailure: false,
		},
		{
			name:        "cancel 499 stays exempt",
			msg:         protocol.InferenceErrorMessage{StatusCode: 499, Error: "request cancelled", FailureCode: protocol.FailureCodeCancelled},
			wantFailure: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
			st := store.NewMemory(store.Config{AdminKey: "test-key"})
			reg := registry.New(logger)
			srv := NewServer(reg, st, ServerConfig{}, logger)
			provider := reg.Register("provider-jinja-"+tc.name, nil, &protocol.RegisterMessage{
				Type:     protocol.TypeRegister,
				Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
				Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
				Backend:  "mlx-swift",
			})
			pr := &registry.PendingRequest{
				RequestID:  "req-jinja",
				Model:      "test-model",
				ChunkCh:    make(chan string, 1),
				CompleteCh: make(chan protocol.UsageInfo, 1),
				ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
			}
			provider.AddPending(pr)

			msg := tc.msg
			msg.RequestID = pr.RequestID
			srv.handleInferenceError(provider.ID, provider, &msg)

			wantFailed := 0
			if tc.wantFailure {
				wantFailed = 1
			}
			if got := provider.Reputation.FailedJobs; got != wantFailed {
				t.Errorf("Reputation.FailedJobs = %d, want %d", got, wantFailed)
			}
			// The terminal is still delivered to the consumer channel either way.
			select {
			case delivered := <-pr.ErrorCh:
				wantStatus := safeInferenceFailureStatus(tc.msg.FailureCode, tc.msg.ErrorReason, tc.msg.TerminalCause, tc.msg.StatusCode)
				if delivered.StatusCode != wantStatus {
					t.Errorf("delivered status = %d, want canonical %d", delivered.StatusCode, wantStatus)
				}
			default:
				t.Error("terminal error was not delivered to ErrorCh")
			}
		})
	}
}

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
		FailureCode: protocol.FailureCodeTemplateRender,
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
