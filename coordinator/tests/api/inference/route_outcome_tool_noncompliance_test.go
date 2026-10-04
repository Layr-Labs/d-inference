package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// The E4 jinja terminal stop must NOT catch a tool_noncompliance 422: the
// violation is output-dependent (another sample / provider can comply), so
// failover continues under the existing 422 policy.
func TestToolNoncompliance422RemainsFailoverable(t *testing.T) {
	s := newTestServerForDispatch(t)
	policy := retry.New(retry.Config{Model: "m", Observation: s.observation})
	result := policy.Decide(protocol.InferenceErrorMessage{StatusCode: 422, Error: "model did not emit the required tool call", ErrorReason: "tool_noncompliance"}, 0)
	if result.Stop {
		t.Fatal("a tool_noncompliance 422 must keep failing over, not stop the ladder")
	}
	if result.ClientStatusCode != 0 {
		t.Fatal("tool_noncompliance must not latch a terminal client error")
	}
}
