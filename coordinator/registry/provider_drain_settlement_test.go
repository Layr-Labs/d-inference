package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestProviderDrainWaitsForEveryReservationRemovalPath(t *testing.T) {
	for _, cleanup := range []string{"remove", "first-content-timeout", "disconnect"} {
		t.Run(cleanup, func(t *testing.T) {
			r := New(testLogger())
			p := registerDrainStateProvider(t, r, "session", 100)
			first, last := drainStateRequest("first"), drainStateRequest("last")
			p.AddPending(first)
			p.AddPending(last)
			generation := r.CommitProviderDrain(p, "drain")
			done, current := r.ProviderDrainPending(p, generation)
			if !current || done == nil || r.CompleteProviderDrain(p, "drain", generation) {
				t.Fatal("drain did not wait for held reservations")
			}
			p.RemovePending(first.RequestID)
			select {
			case <-done:
				t.Fatal("one reservation removal released the other")
			default:
			}
			switch cleanup {
			case "remove":
				p.RemovePending(last.RequestID)
			case "first-content-timeout":
				if removed, deferred := p.RemovePendingForFirstContentTimeout(last.RequestID); removed != last || deferred {
					t.Fatal("timeout did not release its reservation")
				}
			case "disconnect":
				r.Disconnect(p.ID)
			}
			select {
			case <-done:
			default:
				t.Fatal("final cleanup did not signal settlement")
			}
			if r.CompleteProviderDrain(p, "drain", generation) != (cleanup != "disconnect") {
				t.Fatal("settlement did not respect exact live session")
			}
			p.RemovePending(last.RequestID) // duplicate cleanup cannot close twice
			if cleanup == "disconnect" {
				fresh := registerDrainStateProvider(t, r, p.ID, 100)
				if _, current := r.ProviderDrainPending(p, generation); current || r.ProviderDraining(fresh.ID) {
					t.Fatal("disconnected reservation state leaked into a replacement session")
				}
			}
		})
	}
}

func TestReplacementReceiptCannotResumeNewerDrainOrSession(t *testing.T) {
	r := New(testLogger())
	p := registerDrainStateProvider(t, r, "session", 100)
	first := r.CommitProviderDrain(p, "same-id")
	if r.ResumeProviderModels(p, first) {
		t.Fatal("uncommitted inventory resumed admission")
	}
	r.CompleteProviderDrain(p, "same-id", first)
	msg := &protocol.ModelsReplaceMessage{RequestID: "replace", DrainRequestID: "same-id", Models: p.Models}
	_, _, receipt, err := r.ReplaceProviderModels(p, msg)
	if err != nil || !r.ProviderDraining(p.ID) {
		t.Fatalf("inventory commit did not preserve the fence: %v", err)
	}
	r.Heartbeat(p.ID, drainStateHeartbeat("idle"))
	if !r.ProviderDraining(p.ID) {
		t.Fatal("idle heartbeat reopened a commit without its receipt")
	}
	second := r.CommitProviderDrain(p, "same-id")
	if r.ResumeProviderModels(p, receipt) || !r.ProviderDraining(p.ID) {
		t.Fatal("late replacement receipt reopened the newer drain")
	}
	r.CompleteProviderDrain(p, "same-id", second)
	_, _, receipt, err = r.ReplaceProviderModels(p, msg)
	if err != nil {
		t.Fatal(err)
	}
	r.Disconnect(p.ID)
	fresh := registerDrainStateProvider(t, r, p.ID, 100)
	r.CommitProviderDrain(fresh, "same-id")
	if r.ResumeProviderModels(p, receipt) || !r.ProviderDraining(fresh.ID) {
		t.Fatal("old connection receipt reopened another session")
	}
}
