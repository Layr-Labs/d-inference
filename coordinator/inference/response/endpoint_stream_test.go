package response

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestEndpointCompletionClientCancellationPolicy(t *testing.T) {
	for _, policy := range []streamCompletionPolicy{requireCompletionMessage, settledReservationCompletes} {
		s := New(Dependencies{Feedback: endpointCompletionFeedback{}})
		pr := &registry.PendingRequest{CompleteCh: make(chan protocol.UsageInfo)}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		emitter := &recordingEndpointEmitter{}
		done := make(chan struct{})
		t.Cleanup(func() {
			// Release a regressed completion wait before this test exits.
			select {
			case <-done:
				return
			case pr.CompleteCh <- protocol.UsageInfo{CompletionTokens: 7}:
			case <-time.After(time.Second):
				t.Error("completion wait did not accept cleanup usage")
				return
			}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Error("completion wait did not finish after cleanup")
			}
		})
		go func() {
			defer close(done)
			s.finishEndpointStream(ctx, pr, emitter, policy)
		}()
		if policy == requireCompletionMessage {
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("explicit-completion endpoint did not stop on client cancellation")
			}
			if emitter.finished {
				t.Fatal("client cancellation emitted a success terminal")
			}
		} else {
			select {
			case pr.CompleteCh <- protocol.UsageInfo{CompletionTokens: 7}:
			case <-done:
				t.Fatal("Responses stopped its completion wait on client cancellation")
			case <-time.After(time.Second):
				t.Fatal("Responses stopped reading completion usage")
			}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("Responses did not finish after authoritative usage")
			}
			if !emitter.finished || emitter.usage.CompletionTokens != 7 {
				t.Fatalf("Responses lost authoritative usage: %+v", emitter)
			}
		}
	}
}

type recordingEndpointEmitter struct {
	finished bool
	usage    protocol.UsageInfo
}

func (*recordingEndpointEmitter) Start() {}

func (*recordingEndpointEmitter) Chunk(string) {}

func (*recordingEndpointEmitter) Error(string, string) {}

func (e *recordingEndpointEmitter) Finish(u protocol.UsageInfo) { e.finished, e.usage = true, u }

// The policy fixture exercises completion selection without API services.
type endpointCompletionFeedback struct{}

func (endpointCompletionFeedback) Success(*registry.PendingRequest) {}
func (endpointCompletionFeedback) Error(string, *registry.PendingRequest, int, string, string, string, ...protocol.CoordinatorInferenceErrorCause) {
}
