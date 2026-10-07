package inference_test

import (
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Route-outcome taxonomy: a jinja failure is recorded as class client_error
// WITHOUT AdmittedButFailed (not an admission mismatch, not a provider
// fault), while the row's ErrorReason PRESERVES the jinja_* value so the
// inference.error{reason:jinja_*} series keeps measuring real render
// failures.
func TestJinjaRouteOutcome_ClientErrorClassPreservesReason(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	out := routeoutcome.PreCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		StatusCode:  500,
		Error:       "Runtime error: upper filter requires string",
		ErrorReason: "jinja_template",
		FailureCode: protocol.FailureCodeTemplateRender,
	})
	if out.ErrorClass != routeoutcome.ErrorClassClientError {
		t.Fatalf("class = %q, want %q", out.ErrorClass, routeoutcome.ErrorClassClientError)
	}
	if out.AdmittedButFailed {
		t.Fatal("a jinja render failure must NOT set AdmittedButFailed")
	}
	if out.ErrorReason != failure.ErrorReasonJinjaTemplate {
		t.Fatalf("reason = %q, want %q preserved on the row", out.ErrorReason, failure.ErrorReasonJinjaTemplate)
	}

	current := retry.AttemptFailure{Message: protocol.InferenceErrorMessage{
		StatusCode: 500, Error: "upper filter requires string", ErrorReason: "jinja_template",
	}}
	dout := current.RouteOutcome(nil)
	if dout.ErrorClass != routeoutcome.ErrorClassClientError || dout.AdmittedButFailed {
		t.Fatalf("providerFailedRoutingOutcome for jinja: class=%q admitted=%v, want client_error + not admitted", dout.ErrorClass, dout.AdmittedButFailed)
	}
	if dout.ErrorReason != failure.ErrorReasonJinjaTemplate {
		t.Fatalf("providerFailedRoutingOutcome reason = %q, want %q", dout.ErrorReason, failure.ErrorReasonJinjaTemplate)
	}
}
