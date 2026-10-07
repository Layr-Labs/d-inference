package failure_test

import (
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
)

// classifyTerminalCause unit table: every vocabulary value maps to its class
// and only out-of-vocabulary values report unknown.
func TestClassifyTerminalCause(t *testing.T) {
	cases := []struct {
		cause     string
		wantClass failure.TerminalCauseClass
		wantKnown bool
	}{
		{"", failure.CauseClassLegacy, true},
		{failure.TerminalCauseAdmissionTimeout, failure.CauseClassCapacity, true},
		{failure.TerminalCausePrefillStall, failure.CauseClassFault, true},
		{failure.TerminalCauseDecodeStall, failure.CauseClassFault, true},
		{failure.TerminalCauseSafetyDeadline, failure.CauseClassNeutral, true},
		{failure.TerminalCauseBackpressureTimeout, failure.CauseClassNeutral, true},
		{failure.TerminalCauseWatchdog, failure.CauseClassFault, true},
		{failure.TerminalCauseCancelled, failure.CauseClassNeutral, true},
		{failure.TerminalCauseEngineError, failure.CauseClassLegacy, true},
		{"lease_reaped", failure.CauseClassLegacy, false},
		{"SAFETY_DEADLINE", failure.CauseClassLegacy, false}, // vocabulary is exact-match
	}
	for _, tc := range cases {
		class, known := failure.ClassifyTerminalCause(tc.cause)
		if class != tc.wantClass || known != tc.wantKnown {
			t.Errorf("classifyTerminalCause(%q) = (%v, %v), want (%v, %v)",
				tc.cause, class, known, tc.wantClass, tc.wantKnown)
		}
	}
}
