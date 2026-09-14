package dispatch

import (
	"testing"
)

// The E4 jinja terminal stop must NOT catch a tool_noncompliance 422: the
// violation is output-dependent (another sample / provider can comply), so
// failover continues under the existing 422 policy.
func TestToolNoncompliance422RemainsFailoverable(t *testing.T) {
	d := &execution{
		s: newTestController(t), model: "m",
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
