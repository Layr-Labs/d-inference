package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
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
