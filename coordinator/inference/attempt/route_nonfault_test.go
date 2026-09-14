package attempt

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestToolNoncomplianceReasonIsWhitelisted(t *testing.T) {
	if got := NormalizeInferenceErrorReason("tool_noncompliance"); got != ErrorReasonToolNoncompliance {
		t.Fatalf("normalizeInferenceErrorReason(tool_noncompliance) = %q, want %q (must not collapse to unknown)", got, ErrorReasonToolNoncompliance)
	}
	// Wire-casing variants normalize into the same reason.
	if got := NormalizeInferenceErrorReason(" Tool-Noncompliance "); got != ErrorReasonToolNoncompliance {
		t.Fatalf("cased/dashed variant = %q, want %q", got, ErrorReasonToolNoncompliance)
	}
}

func TestToolNoncomplianceOutcomePreservesReason(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	out := PreCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		StatusCode:  422,
		Error:       "model did not emit the required tool call",
		ErrorReason: "tool_noncompliance",
	})
	if out.ErrorReason != ErrorReasonToolNoncompliance {
		t.Fatalf("reason = %q, want %q on the route row", out.ErrorReason, ErrorReasonToolNoncompliance)
	}
}

// isNonProviderFaultErrorReason is the shared vocabulary behind the
// reputation exemption (handleInferenceError) and the dispatch-path breaker
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
		if got := IsNonProviderFaultErrorReason(reason); got != want {
			t.Errorf("isNonProviderFaultErrorReason(%q) = %v, want %v", reason, got, want)
		}
	}
}
