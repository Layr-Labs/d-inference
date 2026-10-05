package inference_test

import (
	"net/http/httptest"
	"strings"
	"testing"

	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestProviderFailedRoutingOutcome_ToolNoncompliance(t *testing.T) {
	d := retry.AttemptFailure{Message: protocol.InferenceErrorMessage{
		StatusCode: 422, Error: "model did not emit the required tool call",
		ErrorReason: "tool_noncompliance",
	}}
	out := d.RouteOutcome(nil)
	if out.ErrorClass != routeoutcome.ErrorClassClientError || out.AdmittedButFailed {
		t.Fatalf("class=%q admitted=%v, want client_error/not-admitted",
			out.ErrorClass, out.AdmittedButFailed)
	}
	if out.ErrorReason != "tool_noncompliance" {
		t.Fatalf("reason = %q, must survive on the row", out.ErrorReason)
	}
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
			msg:        protocol.InferenceErrorMessage{StatusCode: 500, Error: "boom", FailureCode: protocol.FailureCodeGenerationFailure},
			wantStatus: 500, wantType: "provider_error", wantInBody: "inference generation failed", absentBody: "boom",
		},
		{
			name:       "zero status fails closed to 500",
			msg:        protocol.InferenceErrorMessage{Error: "gone", FailureCode: protocol.FailureCodeGenerationFailure},
			wantStatus: 500, wantType: "provider_error", wantInBody: "inference generation failed", absentBody: "gone",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			srv.NewRelay().ProviderError(rec, tc.msg)
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
	srv.NewRelay().ProviderError(rec, protocol.InferenceErrorMessage{FailureCode: protocol.FailureCodeTemplateRender, Error: "Runtime error: upper filter requires string", ErrorReason: "jinja_template"})
	if strings.Contains(rec.Body.String(), "upper filter") {
		t.Fatalf("kill switch off restored raw provider text: status=%d body=%s", rec.Code, rec.Body.String())
	}
}
