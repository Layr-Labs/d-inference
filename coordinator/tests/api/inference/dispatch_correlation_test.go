package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestDispatchRoutingOutcomePreservesMismatchedPendingFallback(t *testing.T) {
	pr := cacheTelemetryPending("other-request")
	owner := &inference.Owner{}
	target := routeoutcome.CaptureAttempt(nil, pr, "current-request", pr.Attempt+1)
	target.Record(owner.NewRouteRecorder(), "model", func(*registry.PendingRequest) *store.InferenceRouteOutcome {
		return routeoutcome.PendingRouteOutcome(nil, routeoutcome.FinalStatusError, "provider_error", 502)
	})
	if !pr.MarkCacheTerminalTelemetryEmitted() {
		t.Fatal("mismatched pending request incorrectly consumed cache terminal hook")
	}
}
