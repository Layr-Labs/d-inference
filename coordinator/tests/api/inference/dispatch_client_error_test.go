package inference_test

import (
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// A client-shape failure is recorded as client_error WITHOUT AdmittedButFailed, so
// it never pollutes the admission-mismatch gauge; a genuine 5xx still does.
func TestClientErrorRouteOutcome_NotAdmittedButFailed(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	out := routeoutcome.PreCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{StatusCode: 400, Error: "invalid tool payload", FailureCode: protocol.FailureCodeInvalidRequest})
	if out.ErrorClass != routeoutcome.ErrorClassClientError {
		t.Fatalf("400 outcome class = %q, want %q", out.ErrorClass, routeoutcome.ErrorClassClientError)
	}
	if out.AdmittedButFailed {
		t.Fatal("a client-shape 4xx must NOT set AdmittedButFailed")
	}
	if out.ErrorReason != failure.ErrorReasonClientError {
		t.Fatalf("400 outcome reason = %q, want %q", out.ErrorReason, failure.ErrorReasonClientError)
	}

	d := retry.AttemptFailure{Message: protocol.InferenceErrorMessage{StatusCode: 400, Error: "invalid tool payload"}}
	dout := d.RouteOutcome(nil)
	if dout.ErrorClass != routeoutcome.ErrorClassClientError || dout.AdmittedButFailed {
		t.Fatalf("providerFailedRoutingOutcome for 400: class=%q admitted=%v", dout.ErrorClass, dout.AdmittedButFailed)
	}

	// A genuine 5xx remains provider_error + AdmittedButFailed.
	fout := routeoutcome.PreCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{StatusCode: 500, Error: "boom", FailureCode: protocol.FailureCodeGenerationFailure})
	if fout.ErrorClass != "provider_error" || !fout.AdmittedButFailed {
		t.Fatalf("500 outcome: class=%q admitted=%v, want provider_error + admitted", fout.ErrorClass, fout.AdmittedButFailed)
	}
}
