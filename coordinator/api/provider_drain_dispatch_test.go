package api

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestProviderDrainAtWriterDoesNotSendOrPublishDispatch(t *testing.T) {
	s, p, peer := dispatchAccountingProvider(t)
	pr := &registry.PendingRequest{RequestID: "reserved-before-stop", Model: dispatchAccountingModel, Timing: &registry.RequestTiming{ReceivedAt: time.Now()}}
	if s.registry.ReserveProvider(dispatchAccountingModel, pr) != p {
		t.Fatal("reserve")
	}
	d := &dispatchState{s: s, provider: p, pr: pr, timing: pr.Timing}
	frame := providerInferenceFrameBuilder(pr.RequestID, "ephemeral", "ciphertext", pr)
	metadata, err := d.writeQueuedProviderInferenceRequest(context.Background(), func(at time.Time) ([]byte, error) {
		s.registry.CommitProviderDrain(p, "stop")
		return frame(at)
	})
	if !errors.Is(err, registry.ErrProviderDraining) || metadata.Committed || d.providerDispatches != 0 || !pr.Timing.DispatchedAt.IsZero() {
		t.Fatalf("drain crossed writer boundary: %+v err=%v dispatches=%d", metadata, err, d.providerDispatches)
	}
	assertDispatchAccountingFrame(t, p, peer, false)
}
