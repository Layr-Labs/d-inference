package api

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestProviderDrainAckWaitsForWriterReservationAndLaterBilling(t *testing.T) {
	s, p, peer := dispatchAccountingProvider(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	pr := &registry.PendingRequest{RequestID: "held-writer", Model: dispatchAccountingModel}
	if s.registry.ReserveProvider(pr.Model, pr) != p {
		t.Fatal("reservation failed")
	}
	handoff := make(chan struct{})
	release := make(chan struct{})
	written := make(chan error, 1)
	go func() {
		_, err := p.WriteInferenceTextDeferred(ctx, pr,
			func(time.Time) ([]byte, error) { return []byte(`{"type":"inference_request"}`), nil },
			func(registry.TextFrameWriteMetadata) {
				close(handoff)
				select {
				case <-release:
				case <-ctx.Done():
				}
			})
		written <- err
	}()
	select {
	case <-handoff:
	case <-ctx.Done():
		t.Fatal("writer did not reach handoff")
	}
	var terminalWork providerCompletionBarrier
	var acker providerDrainAcker
	if !acker.offer(ctx, s, p, &terminalWork, "final") {
		t.Fatal("drain was not committed")
	}
	close(release)
	select {
	case err := <-written:
		if !errors.Is(err, registry.ErrProviderDraining) {
			t.Fatalf("writer crossed drain fence: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("fenced writer did not return")
	}
	// Hold dispatcher cleanup after the data writer rejects the reservation.
	// Control traffic is writable, but it cannot carry a drain ack yet.
	marker := func(name string) {
		t.Helper()
		if err := p.WriteTextControl(ctx, []byte(`{"type":"`+name+`"}`)); err != nil {
			t.Fatal(err)
		}
		readReplacementFrame(t, ctx, peer, name, nil)
	}
	marker("reservation_held")
	if p.PendingCount() != 1 {
		t.Fatal("writer unexpectedly discarded dispatcher-owned reservation")
	}
	// The reader can ingest a terminal AFTER the barrier while reservations
	// settle. Its billing begins before pending removal and must also finish.
	terminalDone := terminalWork.begin()
	p.RemovePending(pr.RequestID)
	marker("billing_held")
	terminalDone()
	var drainAck protocol.ProviderDrainMessage
	readReplacementFrame(t, ctx, peer, protocol.TypeProviderDrainAck, &drainAck)
	if drainAck.RequestID != "final" || p.PendingCount() != 0 {
		t.Fatalf("wrong settled barrier: %+v pending=%d", drainAck, p.PendingCount())
	}
	s.handleModelsReplace(ctx, p, &protocol.ModelsReplaceMessage{
		RequestID: "validate", DrainRequestID: "final", ValidateOnly: true,
		Models: []protocol.ModelInfo{{ID: dispatchAccountingModel}},
	})
	var replacement protocol.ModelsReplaceAckMessage
	readReplacementFrame(t, ctx, peer, protocol.TypeModelsReplaceAck, &replacement)
	if !replacement.Accepted || !replacement.ValidateOnly {
		t.Fatalf("settled writer reservation rejected valid selection: %+v", replacement)
	}
}
