package registry

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestReplaceProviderModelsBoundsUnconfirmedHistory(t *testing.T) {
	for _, tc := range []struct {
		name   string
		cycles int
		id     func(int) string
	}{
		{"count", maxDrainRemovedModels, func(i int) string { return fmt.Sprintf("local/%d", i) }},
		{"bytes", 2, func(i int) string { return strings.Repeat(string(rune('a'+i)), maxDrainRemovedModelBytes/2) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			registration := testRegisterMessage()
			registration.Models = []protocol.ModelInfo{{ID: tc.id(0)}}
			// No serving trust or linked owner is required by this bookkeeping path.
			p := r.Register("unlinked", nil, registration)
			settle := func() uint64 {
				t.Helper()
				generation := r.CommitProviderDrain(p, "drain")
				if generation == 0 || !r.CompleteProviderDrain(p, "drain", generation) {
					t.Fatal("drain did not settle")
				}
				return generation
			}
			for i := 1; i <= tc.cycles; i++ {
				settle()
				_, _, generation, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
					RequestID: "replace", DrainRequestID: "drain", Models: []protocol.ModelInfo{{ID: tc.id(i)}},
				})
				if err != nil || !r.ConfirmProviderModelsReceipt(p, "replace", generation) {
					t.Fatalf("replacement %d within budget failed: %v", i, err)
				}
				// Withhold readiness and repeat the acknowledged drain on this session.
			}
			if len(p.drainRemovedModels) != tc.cycles {
				t.Fatalf("history count = %d, want %d", len(p.drainRemovedModels), tc.cycles)
			}
			generation := settle()
			models := append([]protocol.ModelInfo(nil), p.Models...)
			history := append([]string(nil), p.drainRemovedModels...)
			p.WarmModels = []string{models[0].ID}
			p.CurrentModel = models[0].ID
			p.BackendCapacity = &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: models[0].ID, State: "idle"}}}
			capacity := p.BackendCapacity
			for _, validateOnly := range []bool{true, false} {
				added, removed, receipt, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
					RequestID: "overflow", DrainRequestID: "drain", ValidateOnly: validateOnly,
					Models: []protocol.ModelInfo{{ID: tc.id(tc.cycles + 1)}},
				})
				if err == nil || err.Error() != "invalid_models" || added != nil || removed != nil || receipt != 0 {
					t.Fatalf("overflow accepted: validateOnly=%v err=%v receipt=%d", validateOnly, err, receipt)
				}
				if !reflect.DeepEqual(p.Models, models) || !reflect.DeepEqual(p.drainRemovedModels, history) ||
					p.BackendCapacity != capacity || p.CurrentModel != models[0].ID || !reflect.DeepEqual(p.WarmModels, []string{models[0].ID}) ||
					!p.drainReady || p.drainGeneration != generation || p.drainReplacementPending || !r.ProviderDraining(p.ID) {
					t.Fatal("overflow mutated inventory, history, residency, or drain")
				}
				assertModelIndexConsistent(t, r)
			}
			// Restoring an old ID frees its history entry before charging the current
			// removal, so recovery remains possible even at the exact budget.
			_, _, receipt, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
				RequestID: "restore", DrainRequestID: "drain", Models: []protocol.ModelInfo{{ID: tc.id(0)}},
			})
			if err != nil || !r.ConfirmProviderModelsReceipt(p, "restore", receipt) {
				t.Fatalf("restoration at the budget failed: %v", err)
			}
			markReplacementCapacityFresh(p)
			_, removed, resumed, _ := r.ResumeProviderModels(p, "restore", "drain", 1)
			wantRemoved := append(append([]string(nil), history[1:]...), models[0].ID)
			if !resumed || !reflect.DeepEqual(removed, wantRemoved) || p.drainRemovedModels != nil || r.ProviderDraining(p.ID) {
				t.Fatal("recovery dropped cleanup or failed to release history after readiness")
			}
			// A resumed session has a fresh budget. Disconnect also releases history.
			settle()
			if _, _, _, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
				RequestID: "after-resume", DrainRequestID: "drain", Models: models,
			}); err != nil {
				t.Fatalf("resume did not reset history budget: %v", err)
			}
			r.Disconnect(p.ID)
			if p.drainRemovedModels != nil {
				t.Fatal("disconnect retained history")
			}
		})
	}
}
