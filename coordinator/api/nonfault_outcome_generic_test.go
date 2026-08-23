package api

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// PR #548 review round 3 (Codex P2): tool_noncompliance route rows must not be
// provider-failure outcomes. The outcome builders key on the SAME shared
// vocabulary as the reputation and breaker exemptions
// (isNonProviderFaultErrorReason), so the lists cannot drift.

func TestPreCommitOutcome_NonProviderFaultReasons(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	for _, tc := range []struct {
		code   int
		reason string
	}{
		{422, "tool_noncompliance"},
		{500, "jinja_template"},
	} {
		out := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
			StatusCode: tc.code, Error: "x", ErrorReason: tc.reason,
		})
		if out.ErrorClass != errorClassClientError {
			t.Fatalf("%s: class = %q, want %q", tc.reason, out.ErrorClass, errorClassClientError)
		}
		if out.AdmittedButFailed {
			t.Fatalf("%s: AdmittedButFailed must stay false", tc.reason)
		}
		if out.ErrorReason != tc.reason {
			t.Fatalf("%s: reason = %q, must survive on the row", tc.reason, out.ErrorReason)
		}
	}

	// Control: a plain 422 with NO structured reason stays a provider-fault
	// outcome — the reclassification cannot widen to generic output-validation
	// errors.
	ctrl := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		StatusCode: 422, Error: "model output was not valid JSON",
	})
	if ctrl.ErrorClass != "provider_error" || !ctrl.AdmittedButFailed {
		t.Fatalf("plain 422: class=%q admitted=%v, want provider_error/admitted",
			ctrl.ErrorClass, ctrl.AdmittedButFailed)
	}
	if ctrl.ErrorCode != http.StatusInternalServerError {
		t.Fatalf("plain legacy 422 must fail closed to canonical 500, got %d", ctrl.ErrorCode)
	}
}

func TestProviderFailedRoutingOutcome_ToolNoncompliance(t *testing.T) {
	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode: 422, lastErr: "model did not emit the required tool call",
		lastErrReason: "tool_noncompliance",
	}
	out := d.providerFailedRoutingOutcome()
	if out.ErrorClass != errorClassClientError || out.AdmittedButFailed {
		t.Fatalf("class=%q admitted=%v, want client_error/not-admitted",
			out.ErrorClass, out.AdmittedButFailed)
	}
	if out.ErrorReason != "tool_noncompliance" {
		t.Fatalf("reason = %q, must survive on the row", out.ErrorReason)
	}
}

// PR #548 review round 3 (Codex P2): the generic inference path
// (/v1/messages, /v1/completions) calls noteInferenceError DIRECTLY on
// pre-commit provider errors, bypassing the dispatch funnel's gate. The gate
// now lives inside noteInferenceError itself (the single breaker chokepoint),
// so jinja_*/tool_noncompliance never feed the provider-fault breakers from
// any path. Fails without the noteInferenceError gate.
func TestGenericPathNonFaultReasonsSkipBreakers(t *testing.T) {
	srv, reg, provider, pr := newBreakerExemptionHarness(t, "generic-nonfault")

	// Far past every trip threshold (pair cooldown trips at 2, node health at
	// 5, stable identity at 8).
	for range 10 {
		srv.noteInferenceError(provider.ID, pr, http.StatusInternalServerError,
			"Runtime error: upper filter requires string", "jinja_template", "")
		srv.noteInferenceError(provider.ID, pr, 422,
			"model did not emit the required tool call", "tool_noncompliance", "")
	}
	assertBreakerStates(t, reg, provider, pr, false)

	// Control: the same volume of plain 500s through the same chokepoint still
	// trips the breakers — the gate keys on the structured reason only.
	for range 10 {
		srv.noteInferenceError(provider.ID, pr, http.StatusInternalServerError, "boom", "", "")
	}
	assertBreakerStates(t, reg, provider, pr, true)
}

// PR #548 review round 4 (Codex P2): the generic endpoints (/v1/messages,
// /v1/completions) and the non-streaming chat assembly must surface the SAME
// curated bodies as the chat dispatch ladder for non-provider-fault reasons —
// never the raw template backtrace as a retryable-looking provider_error 500.
func TestWriteGenericProviderError(t *testing.T) {
	srv := newTestServerForDispatch(t)

	cases := []struct {
		name       string
		msg        protocol.InferenceErrorMessage
		wantStatus int
		wantType   string
		wantInBody string
		absentBody string
	}{
		{
			name:       "jinja becomes curated 422",
			msg:        protocol.InferenceErrorMessage{FailureCode: protocol.FailureCodeTemplateRender, Error: "Runtime error: upper filter requires string", ErrorReason: "jinja_template"},
			wantStatus: 422, wantType: "invalid_request_error",
			wantInBody: "model_capability", absentBody: "upper filter",
		},
		{
			name:       "tool_noncompliance keeps safe typed envelope",
			msg:        protocol.InferenceErrorMessage{FailureCode: protocol.FailureCodeGenerationFailure, Error: "model did not emit the required tool call", ErrorReason: "tool_noncompliance"},
			wantStatus: 422, wantType: "invalid_request_error",
			wantInBody: "inference generation failed", absentBody: "required tool call",
		},
		{
			name:       "plain 500 is fixed generation failure",
			msg:        protocol.InferenceErrorMessage{StatusCode: 500, Error: "boom"},
			wantStatus: 500, wantType: "provider_error", wantInBody: "inference generation failed", absentBody: "boom",
		},
		{
			name:       "zero status fails closed to 500",
			msg:        protocol.InferenceErrorMessage{Error: "gone"},
			wantStatus: 500, wantType: "provider_error", wantInBody: "inference generation failed", absentBody: "gone",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			srv.writeGenericProviderError(rec, tc.msg)
			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tc.wantStatus)
			}
			body := rec.Body.String()
			if !strings.Contains(body, tc.wantType) || !strings.Contains(body, tc.wantInBody) {
				t.Fatalf("body = %s, want type %q and %q", body, tc.wantType, tc.wantInBody)
			}
			if tc.absentBody != "" && strings.Contains(body, tc.absentBody) {
				t.Fatalf("body must not leak %q: %s", tc.absentBody, body)
			}
		})
	}

	// The rollout kill switch may change the envelope classification, but raw
	// provider text is never restored.
	t.Setenv("EIGENINFERENCE_JINJA_TERMINAL_REJECT", "false")
	rec := httptest.NewRecorder()
	srv.writeGenericProviderError(rec, protocol.InferenceErrorMessage{FailureCode: protocol.FailureCodeTemplateRender, Error: "Runtime error: upper filter requires string", ErrorReason: "jinja_template"})
	if strings.Contains(rec.Body.String(), "upper filter") {
		t.Fatalf("kill switch off restored raw provider text: status=%d body=%s", rec.Code, rec.Body.String())
	}
}
func TestToolNoncomplianceReasonIsWhitelisted(t *testing.T) {
	if got := normalizeInferenceErrorReason("tool_noncompliance"); got != errorReasonToolNoncompliance {
		t.Fatalf("normalizeInferenceErrorReason(tool_noncompliance) = %q, want %q (must not collapse to unknown)", got, errorReasonToolNoncompliance)
	}
	// Wire-casing variants normalize into the same reason.
	if got := normalizeInferenceErrorReason(" Tool-Noncompliance "); got != errorReasonToolNoncompliance {
		t.Fatalf("cased/dashed variant = %q, want %q", got, errorReasonToolNoncompliance)
	}
}

// exemption (noteProviderError): jinja_* + tool_noncompliance, nothing else.
func TestIsNonProviderFaultErrorReason(t *testing.T) {
	for reason, want := range map[string]bool{
		"jinja_template":         true,
		"jinja_channel_tags":     true,
		"jinja_null_bridge":      true,
		"tool_noncompliance":     true,
		" Tool-Noncompliance ":   true, // wire casing/dashes normalize
		"":                       false,
		"provider_error":         false,
		"client_error":           false, // generic client shape ≠ exonerating
		"model_load":             false, // load faults ARE provider faults
		"cancelled":              false, // cancel exemption is status/string-driven
		"token_budget_exhausted": false, // capacity exemption is status/string-driven
		"unknown":                false,
	} {
		if got := isNonProviderFaultErrorReason(reason); got != want {
			t.Errorf("isNonProviderFaultErrorReason(%q) = %v, want %v", reason, got, want)
		}
	}
}

// handleInferenceError must NOT record a reputation failure for a
// tool_noncompliance 422 — the MODEL's output, not the provider, broke the
// forced tool_choice contract (mirrors the jinja_* exemption in
// TestHandleInferenceError_JinjaSkipsRecordJobFailure). A plain 422 with no
// structured reason still counts, so the exemption cannot over-widen.
// The tool_noncompliance case FAILS without the isNonProviderFaultErrorReason
// exemption in handleInferenceError.
func TestHandleInferenceError_ToolNoncomplianceSkipsRecordJobFailure(t *testing.T) {
	cases := []struct {
		name        string
		msg         protocol.InferenceErrorMessage
		wantFailure bool
	}{
		{
			name: "tool_noncompliance 422 is exempt",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "model did not emit the required tool call",
				ErrorReason: "tool_noncompliance",
			},
			wantFailure: false,
		},
		{
			name: "wire-cased tool_noncompliance normalizes into the exemption",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "model emitted a tool call outside tool_choice",
				ErrorReason: " Tool-Noncompliance ",
			},
			wantFailure: false,
		},
		{
			name: "plain 422 with no structured reason still records a failure",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "model output was not valid JSON",
			},
			wantFailure: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
			st := store.NewMemory(store.Config{AdminKey: "test-key"})
			reg := registry.New(logger)
			srv := NewServer(reg, st, ServerConfig{}, logger)
			provider := reg.Register("provider-toolnc-"+tc.name, nil, &protocol.RegisterMessage{
				Type:     protocol.TypeRegister,
				Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
				Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
				Backend:  "mlx-swift",
			})
			pr := &registry.PendingRequest{
				RequestID:  "req-toolnc",
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
				wantStatus := safeInferenceFailureStatus(
					delivered.FailureCode, delivered.ErrorReason, delivered.TerminalCause, delivered.StatusCode)
				if delivered.StatusCode != wantStatus {
					t.Errorf("delivered status = %d, want canonical %d", delivered.StatusCode, wantStatus)
				}
			default:
				t.Error("terminal error was not delivered to ErrorCh")
			}
		})
	}
}

// The E4 jinja terminal stop must NOT catch a tool_noncompliance 422: the
// violation is output-dependent (another sample / provider can comply), so
// failover continues under the existing 422 policy.
func TestToolNoncompliance422RemainsFailoverable(t *testing.T) {
	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode:   422,
		lastErr:       "model did not emit the required tool call",
		lastErrReason: "tool_noncompliance",
	}
	if d.shouldStopFailover() {
		t.Fatal("a tool_noncompliance 422 must keep failing over, not stop the ladder")
	}
	if d.terminalClientError {
		t.Fatal("tool_noncompliance must not latch a terminal client error")
	}
}
