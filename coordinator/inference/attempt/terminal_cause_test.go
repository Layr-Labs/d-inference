package attempt

import (
	"testing"
)

// ClassifyTerminalCause unit table: every vocabulary value maps to its class
// and only out-of-vocabulary values report unknown.
func TestClassifyTerminalCause(t *testing.T) {
	cases := []struct {
		cause     string
		wantClass TerminalCauseClass
		wantKnown bool
	}{
		{"", CauseClassLegacy, true},
		{TerminalCauseAdmissionTimeout, CauseClassCapacity, true},
		{TerminalCausePrefillStall, CauseClassFault, true},
		{TerminalCauseDecodeStall, CauseClassFault, true},
		{TerminalCauseSafetyDeadline, CauseClassNeutral, true},
		{TerminalCauseBackpressureTimeout, CauseClassNeutral, true},
		{TerminalCauseWatchdog, CauseClassFault, true},
		{TerminalCauseCancelled, CauseClassNeutral, true},
		{TerminalCauseEngineError, CauseClassLegacy, true},
		{"lease_reaped", CauseClassLegacy, false},
		{"SAFETY_DEADLINE", CauseClassLegacy, false}, // vocabulary is exact-match
	}
	for _, tc := range cases {
		class, known := ClassifyTerminalCause(tc.cause)
		if class != tc.wantClass || known != tc.wantKnown {
			t.Errorf("classifyTerminalCause(%q) = (%v, %v), want (%v, %v)",
				tc.cause, class, known, tc.wantClass, tc.wantKnown)
		}
	}
}
