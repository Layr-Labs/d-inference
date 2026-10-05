package inference_test

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstContentDoesNotWaitForUnforecastableCapacity(t *testing.T) {
	s, _, pr, req := waitDeadlineFixture(t, 0, time.Second)
	request := inference.PrimaryRequest{
		Dispatch: providerdispatch.Input{Request: req, Model: pr.Model, Timing: pr.Timing, Deadline: time.Second},
		Writer:   httptest.NewRecorder(),
	}
	primary := s.NewPrimary(inference.PrimaryResources{})
	refunds := 0
	request.Refund = func() { refunds++ }
	if !primary.RejectUnforecastable(request, registry.RoutingDecision{CapacityRejections: 1}) || refunds != 1 {
		t.Fatalf("unforecastable wait retained: refunds=%d", refunds)
	}
	for _, policy := range []providerdispatch.Scope{{SelfRouteOnly: true}, {PreferOwner: true}} {
		request.Dispatch.Scope = policy
		if primary.RejectUnforecastable(request, registry.RoutingDecision{CapacityRejections: 1}) {
			t.Fatal("owner-directed queue policy changed")
		}
	}
	request.Dispatch.Scope, request.Dispatch.Deadline = providerdispatch.Scope{}, 0
	if primary.RejectUnforecastable(request, registry.RoutingDecision{CapacityRejections: 1}) {
		t.Fatal("deadline-exempt queue policy changed")
	}
}
