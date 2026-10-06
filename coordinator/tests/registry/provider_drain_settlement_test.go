package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestReplacementReadinessWaitsForAppliedServingCapacity(t *testing.T) {
	r := production.New(testLogger())
	p := registerDrainStateProvider(t, r, "session", 100)
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1},
	}) {
		t.Fatal("initial capacity was not applied")
	}
	generation := r.CommitProviderDrain(p, "drain")
	r.CompleteProviderDrain(p, "drain", generation)
	_, _, receipt, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
		RequestID: "replace", DrainRequestID: "drain", Models: p.Models,
	})
	if err != nil || !r.ConfirmProviderModelsReceipt(p, "replace", receipt) {
		t.Fatalf("replacement receipt: %v", err)
	}
	if _, _, resumed, _ := r.ResumeProviderModels(p, "replace", "drain", 3); resumed {
		t.Fatal("readiness reopened routing with pre-switch capacity")
	}
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "draining", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 2},
	}) {
		t.Fatal("draining capacity was not applied")
	}
	if _, _, resumed, _ := r.ResumeProviderModelsAfterHeartbeat(p); resumed {
		t.Fatal("draining capacity reopened routing")
	}
	if r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1},
	}) {
		t.Fatal("stale capacity sequence was applied")
	}
	if _, _, resumed, _ := r.ResumeProviderModelsAfterHeartbeat(p); resumed {
		t.Fatal("stale serving capacity reopened routing")
	}
	free := 2.0
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 3, FreeForLoadGB: &free},
	}) {
		t.Fatal("fresh serving capacity was not applied")
	}
	if _, _, resumed, _ := r.ResumeProviderModelsAfterHeartbeat(p); !resumed || r.ProviderDraining(p.ID) {
		t.Fatal("matching readiness and fresh capacity did not reopen routing")
	}
	if got := p.BackendCapacitySnapshot(); got == nil || got.FreeForLoadGB == nil || *got.FreeForLoadGB != free {
		t.Fatalf("routing resumed without the refreshed load budget: %+v", got)
	}
}

func TestReplacementCapacityMayArriveBeforeReadyFrame(t *testing.T) {
	r := production.New(testLogger())
	p := registerDrainStateProvider(t, r, "session", 100)
	generation := r.CommitProviderDrain(p, "drain")
	r.CompleteProviderDrain(p, "drain", generation)
	_, _, receipt, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
		RequestID: "replace", DrainRequestID: "drain", Models: p.Models,
	})
	if err != nil || !r.ConfirmProviderModelsReceipt(p, "replace", receipt) {
		t.Fatalf("replacement receipt: %v", err)
	}
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1},
	}) {
		t.Fatal("fresh capacity was not applied")
	}
	if _, _, resumed, _ := r.ResumeProviderModelsAfterHeartbeat(p); resumed || !r.ProviderDraining(p.ID) {
		t.Fatal("capacity alone reopened routing")
	}
	if _, _, resumed, _ := r.ResumeProviderModels(p, "replace", "drain", 1); !resumed || r.ProviderDraining(p.ID) {
		t.Fatal("matching ready frame did not complete the replacement")
	}
}

func TestDuplicateReadyCannotLowerRequiredCapacitySequence(t *testing.T) {
	r := production.New(testLogger())
	p := registerDrainStateProvider(t, r, "session", 100)
	generation := r.CommitProviderDrain(p, "drain")
	r.CompleteProviderDrain(p, "drain", generation)
	_, _, receipt, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
		RequestID: "replace", DrainRequestID: "drain", Models: p.Models,
	})
	if err != nil || !r.ConfirmProviderModelsReceipt(p, "replace", receipt) {
		t.Fatalf("replacement receipt: %v", err)
	}
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1},
	}) {
		t.Fatal("older serving heartbeat was not applied")
	}
	for _, readySeq := range []uint64{3, 1} {
		if _, _, resumed, _ := r.ResumeProviderModels(p, "replace", "drain", readySeq); resumed {
			t.Fatal("older duplicate readiness lowered the required capacity sequence")
		}
	}
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 3},
	}) {
		t.Fatal("newer serving heartbeat was not applied")
	}
	if _, _, resumed, _ := r.ResumeProviderModelsAfterHeartbeat(p); !resumed {
		t.Fatal("required serving capacity did not complete the replacement")
	}
}

func TestProviderDrainWaitsForEveryReservationRemovalPath(t *testing.T) {
	for _, cleanup := range []string{"remove", "first-content-timeout", "disconnect"} {
		t.Run(cleanup, func(t *testing.T) {
			r := production.New(testLogger())
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
	r := production.New(testLogger())
	p := registerDrainStateProvider(t, r, "session", 100)
	first := r.CommitProviderDrain(p, "same-id")
	if _, _, resumed, _ := r.ResumeProviderModels(p, "replace", "same-id", 1); resumed {
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
	if _, _, resumed, _ := r.ResumeProviderModels(p, "replace", "same-id", 1); resumed {
		t.Fatal("provider readiness reopened before the receipt reached the wire")
	}
	if !r.ConfirmProviderModelsReceipt(p, "replace", receipt) {
		t.Fatal("could not confirm committed receipt")
	}
	for _, correlation := range [][2]string{{"other", "same-id"}, {"replace", "other"}} {
		if _, _, resumed, _ := r.ResumeProviderModels(p, correlation[0], correlation[1], 1); resumed || !r.ProviderDraining(p.ID) {
			t.Fatal("mismatched readiness reopened admission")
		}
	}
	second := r.CommitProviderDrain(p, "same-id")
	if _, _, resumed, _ := r.ResumeProviderModels(p, "replace", "same-id", 1); resumed || !r.ProviderDraining(p.ID) {
		t.Fatal("late replacement receipt reopened the newer drain")
	}
	r.CompleteProviderDrain(p, "same-id", second)
	_, _, receipt, err = r.ReplaceProviderModels(p, msg)
	if err != nil {
		t.Fatal(err)
	}
	if !r.ConfirmProviderModelsReceipt(p, "replace", receipt) {
		t.Fatal("could not confirm second receipt")
	}
	r.Disconnect(p.ID)
	fresh := registerDrainStateProvider(t, r, p.ID, 100)
	r.CommitProviderDrain(fresh, "same-id")
	if _, _, resumed, _ := r.ResumeProviderModels(p, "replace", "same-id", 1); resumed || !r.ProviderDraining(fresh.ID) {
		t.Fatal("old connection receipt reopened another session")
	}
}

func TestReplacementRemovalsSurviveReconciliationDrain(t *testing.T) {
	for _, restored := range []bool{false, true} {
		r := production.New(testLogger())
		p := registerDrainStateProvider(t, r, "session", 100)
		oldID := p.Models[0].ID
		first := r.CommitProviderDrain(p, "first")
		r.CompleteProviderDrain(p, "first", first)
		_, removed, _, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
			RequestID: "unconfirmed", DrainRequestID: "first", Models: []protocol.ModelInfo{{ID: "new"}},
		})
		if err != nil || len(removed) != 1 || removed[0] != oldID {
			t.Fatalf("initial removal: removed=%v err=%v", removed, err)
		}
		second := r.CommitProviderDrain(p, "second")
		r.CompleteProviderDrain(p, "second", second)
		models := []protocol.ModelInfo{{ID: "new"}}
		if restored {
			models = append(models, protocol.ModelInfo{ID: oldID})
		}
		_, _, receipt, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
			RequestID: "retry", DrainRequestID: "second", Models: models,
		})
		if err != nil || !r.ConfirmProviderModelsReceipt(p, "retry", receipt) {
			t.Fatalf("retry receipt: %v", err)
		}
		r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
			Status: "idle", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1},
		})
		_, pendingRemoved, resumed, _ := r.ResumeProviderModels(p, "retry", "second", 1)
		if !resumed || (len(pendingRemoved) == 1) != !restored {
			t.Fatalf("reconciliation removals restored=%v: %v", restored, pendingRemoved)
		}
		if !restored && pendingRemoved[0] != oldID {
			t.Fatalf("wrong pending removal: %v", pendingRemoved)
		}
	}
}
