package inference_test

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstContentSLAExemptionHasNoFirstContentTimer(t *testing.T) {
	receivedAt := time.Now().Add(-time.Minute)
	clock := firstcontent.NewClock(receivedAt, 0, 4*time.Second)
	if clock.Expired() {
		t.Fatal("exempt request expired")
	}
	if wait := clock.Wait(-time.Second); wait != 0 {
		t.Fatal(wait)
	}
	if wait := clock.SpeculativeWait(); wait != 4*time.Second {
		t.Fatal("exemption caused immediate hedge", wait)
	}
	if ms, ok := firstcontent.FirstContentBudgetMillis(receivedAt, 0); !ok || ms != 0 {
		t.Fatalf("disabled budget: %d %v", ms, ok)
	}
	if routeplan.TTFTTooSlow(time.Hour, true, 0) {
		t.Fatal("disabled ceiling rejected candidate")
	}
	ctx, cancel := context.WithCancel(context.Background())
	writeCtx, done := firstcontent.FirstTokenWriteContext(ctx, receivedAt, 0)
	defer done()
	if _, set := writeCtx.Deadline(); set {
		t.Fatal("exempt write inherited SLA")
	}
	cancel()
	select {
	case <-writeCtx.Done():
	default:
		t.Fatal("client cancellation lost")
	}
}

func TestFirstContentSLAExemptQueueWaitHonorsClientCancellation(t *testing.T) {
	s := newTestServerForDispatch(t)
	s.registry.SetQueue(registry.NewRequestQueue(4, 5*time.Second))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	timer := time.AfterFunc(80*time.Millisecond, cancel)
	defer timer.Stop()
	refunded := false
	request := inference.PrimaryRequest{
		Dispatch: providerdispatch.Input{
			Request: httptest.NewRequest("POST", "/v1/completions", nil).WithContext(ctx),
			Model:   "exempt-queue", PublicModel: "exempt-queue", Body: []byte(`{"model":"exempt-queue","messages":[]}`),
			Timing:   &registry.RequestTiming{ReceivedAt: time.Now().Add(-time.Minute)},
			Deadline: 0, Exclusions: providerdispatch.NewExclusions(),
			RequestedMaxTokens: 16, EstimatedPromptTokens: 1,
		},
		Metadata: providerdispatch.PendingMetadata{Endpoint: inreq.CompletionsEndpoint},
		Writer:   httptest.NewRecorder(), SpeculativeAt: time.Second, Refund: func() { refunded = true },
	}
	primary := s.NewPrimary(inference.PrimaryResources{})
	started := time.Now()
	if got := primary.Run(request).Outcome; got != attempt.ClientGone {
		t.Fatalf("queue outcome=%v", got)
	}
	if time.Since(started) < 50*time.Millisecond {
		t.Fatal("exemption recreated an expired clock")
	}
	if !refunded || s.registry.Queue().QueueSize(request.Dispatch.Model) != 0 {
		t.Fatal("cancelled queue leaked reservation or entry")
	}
}
