package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// E5: providers map a forced-tool_choice violation ("model did not emit the
// required tool call" / "outside tool_choice" / "deferred content limit") to a
// typed 422 with error_reason "tool_noncompliance". The coordinator must
// accept the reason into durable telemetry (whitelist) and keep the 422 on the
// normal bounded-failover path — a re-sample can comply.

func TestToolNoncomplianceReasonIsWhitelisted(t *testing.T) {
	if got := normalizeInferenceErrorReason("tool_noncompliance"); got != errorReasonToolNoncompliance {
		t.Fatalf("normalizeInferenceErrorReason(tool_noncompliance) = %q, want %q (must not collapse to unknown)", got, errorReasonToolNoncompliance)
	}
	// Wire-casing variants normalize into the same reason.
	if got := normalizeInferenceErrorReason(" Tool-Noncompliance "); got != errorReasonToolNoncompliance {
		t.Fatalf("cased/dashed variant = %q, want %q", got, errorReasonToolNoncompliance)
	}
}

func TestToolNoncomplianceOutcomePreservesReason(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	out := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		StatusCode:  422,
		Error:       "model did not emit the required tool call",
		ErrorReason: "tool_noncompliance",
	})
	if out.ErrorReason != errorReasonToolNoncompliance {
		t.Fatalf("reason = %q, want %q on the route row", out.ErrorReason, errorReasonToolNoncompliance)
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
