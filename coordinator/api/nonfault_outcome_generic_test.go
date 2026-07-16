package api

import (
	"net/http"
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
			"Runtime error: upper filter requires string", "jinja_template")
		srv.noteInferenceError(provider.ID, pr, 422,
			"model did not emit the required tool call", "tool_noncompliance")
	}
	assertBreakerStates(t, reg, provider, pr, false)

	// Control: the same volume of plain 500s through the same chokepoint still
	// trips the breakers — the gate keys on the structured reason only.
	for range 10 {
		srv.noteInferenceError(provider.ID, pr, http.StatusInternalServerError, "boom", "")
	}
	assertBreakerStates(t, reg, provider, pr, true)
}
