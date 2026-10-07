package failure_test

import (
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
)

func TestToolNoncomplianceReasonIsWhitelisted(t *testing.T) {
	if got := failure.NormalizeReason("tool_noncompliance"); got != failure.ErrorReasonToolNoncompliance {
		t.Fatalf("normalizeInferenceErrorReason(tool_noncompliance) = %q, want %q (must not collapse to unknown)", got, failure.ErrorReasonToolNoncompliance)
	}
	// Wire-casing variants normalize into the same reason.
	if got := failure.NormalizeReason(" Tool-Noncompliance "); got != failure.ErrorReasonToolNoncompliance {
		t.Fatalf("cased/dashed variant = %q, want %q", got, failure.ErrorReasonToolNoncompliance)
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
		if got := failure.IsNonProviderFaultErrorReason(reason); got != want {
			t.Errorf("isNonProviderFaultErrorReason(%q) = %v, want %v", reason, got, want)
		}
	}
}
