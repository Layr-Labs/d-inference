package api

import (
	"context"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestProviderCompletionBarrierWaitsForSettlementAndIsIdempotent(t *testing.T) {
	var barrier providerCompletionBarrier
	first, second := barrier.begin(), barrier.begin()
	pending := barrier.snapshot()
	if len(pending) != 2 {
		t.Fatal("lost terminal worker")
	}
	first()
	first() // duplicate cleanup cannot close twice or lose the other worker
	if len(barrier.snapshot()) != 1 {
		t.Fatal("duplicate completion changed pending settlement")
	}
	third := barrier.begin() // later frames are outside this barrier's snapshot
	second()
	for _, done := range pending {
		select {
		case <-done:
		default:
			t.Fatal("settled terminal still blocked")
		}
	}
	if len(barrier.snapshot()) != 1 {
		t.Fatal("barrier incorrectly consumed later work")
	}
	third()
	if len(barrier.snapshot()) != 0 {
		t.Fatal("settlement leaked")
	}
}

func TestProviderCompletionBarrierReusedDrainIDWaitsForLatestSettlement(t *testing.T) {
	reg := registry.New(slog.Default())
	provider := reg.Register("session", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "old"}}})
	defer reg.Disconnect(provider.ID)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var barrier providerCompletionBarrier
	firstTerminal := barrier.begin()
	firstGeneration := reg.CommitProviderDrain(provider, "same-id")
	firstSnapshot := barrier.snapshot()
	// The read loop ingresses a later inference_complete and removes its
	// reservation before billing settles, then receives the same drain ID.
	secondTerminal := barrier.begin()
	secondGeneration := reg.CommitProviderDrain(provider, "same-id")
	secondSnapshot := barrier.snapshot()
	settle := func(snapshot []<-chan struct{}, generation uint64) <-chan bool {
		ready := make(chan bool, 1)
		go func() {
			for _, done := range snapshot {
				select {
				case <-done:
				case <-ctx.Done():
					return
				}
			}
			ready <- reg.CompleteProviderDrain(provider, "same-id", generation)
		}()
		return ready
	}
	firstAck := settle(firstSnapshot, firstGeneration)
	secondAck := settle(secondSnapshot, secondGeneration)
	firstTerminal()
	select {
	case ready := <-firstAck:
		if ready {
			t.Fatal("older terminal snapshot authorized the reused drain ID")
		}
	case <-ctx.Done():
		t.Fatal("first settlement did not finish")
	}
	msg := &protocol.ModelsReplaceMessage{
		RequestID: "validate", DrainRequestID: "same-id", ValidateOnly: true,
		Models: []protocol.ModelInfo{{ID: "new"}},
	}
	if _, _, err := reg.ReplaceProviderModels(provider, msg); err == nil || err.Error() != "invalid_drain" {
		t.Fatalf("validation crossed later unsettled billing: %v", err)
	}
	secondTerminal()
	select {
	case ready := <-secondAck:
		if !ready {
			t.Fatal("latest terminal snapshot did not settle its drain")
		}
	case <-ctx.Done():
		t.Fatal("latest settlement did not finish")
	}
	if _, _, err := reg.ReplaceProviderModels(provider, msg); err != nil {
		t.Fatalf("settled validation rejected: %v", err)
	}
	if !reg.ProviderDraining(provider.ID) || provider.Models[0].ID != "old" {
		t.Fatal("validation changed the old inventory or resumed admission")
	}
	msg.ValidateOnly = false
	if _, _, err := reg.ReplaceProviderModels(provider, msg); err != nil || reg.ProviderDraining(provider.ID) || provider.Models[0].ID != "new" {
		t.Fatalf("latest settled drain could not commit: %v", err)
	}
}
