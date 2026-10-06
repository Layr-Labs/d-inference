package inference_test

import (
	"context"
	"errors"
	"testing"
	"time"

	providerwire "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestProviderDrainAtWriterDoesNotSendOrPublishDispatch(t *testing.T) {
	s, p, peer := dispatchAccountingProvider(t)
	pr := &registry.PendingRequest{RequestID: "reserved-before-stop", Model: dispatchAccountingModel, Timing: &registry.RequestTiming{ReceivedAt: time.Now()}}
	if s.registry.ReserveProvider(dispatchAccountingModel, pr) != p {
		t.Fatal("reserve")
	}
	d := &providerwire.Accounting{}
	frame := providerwire.FrameBuilder(pr.RequestID, "ephemeral", "ciphertext", pr)
	metadata, err := d.WriteQueued(context.Background(), p, pr, func(at time.Time) ([]byte, error) {
		s.registry.CommitProviderDrain(p, "stop")
		return frame(at)
	})
	if !errors.Is(err, registry.ErrProviderDraining) || metadata.Committed || d.Count() != 0 || !pr.Timing.DispatchedAt.IsZero() {
		t.Fatalf("drain crossed writer boundary: %+v err=%v dispatches=%d", metadata, err, d.Count())
	}
	assertDispatchAccountingFrame(t, p, peer, false)
}
