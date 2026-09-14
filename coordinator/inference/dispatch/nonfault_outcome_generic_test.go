package dispatch

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
)

func TestProviderFailedRoutingOutcome_ToolNoncompliance(t *testing.T) {
	d := &execution{
		s: newTestController(t), model: "m",
		lastErrCode: 422, lastErr: "model did not emit the required tool call",
		lastErrReason: "tool_noncompliance",
	}
	out := d.providerFailedRoutingOutcome()
	if out.ErrorClass != attempt.ErrorClassClientError || out.AdmittedButFailed {
		t.Fatalf("class=%q admitted=%v, want client_error/not-admitted",
			out.ErrorClass, out.AdmittedButFailed)
	}
	if out.ErrorReason != "tool_noncompliance" {
		t.Fatalf("reason = %q, must survive on the row", out.ErrorReason)
	}
}
