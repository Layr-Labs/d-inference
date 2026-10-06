package registry_test

import (
	"reflect"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/modelindex"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestReplaceProviderModelsUsesRevisionApprovals(t *testing.T) {
	for _, tc := range []struct {
		name, hash string
		accepted   bool
		keepWarm   bool
	}{
		{"active", "current", true, false},
		{"retained", "old", true, true},
		{"retained case insensitive", "OLD", true, true},
		{"unapproved", "unknown", false, false},
		{"missing", "", false, false},
		{"another model", "other-hash", false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			index := &modelIndexFixture{index: &modelindex.Index[*production.Provider]{}, memberships: make(map[string]*modelindex.Membership)}
			drains := make(providerDrainAuthorities)
			deps := index.dependencies()
			deps.ProviderDrains = drains.bind
			r := production.NewWithDependencies(testLogger(), deps)
			p := registerDrainStateProvider(t, r, "session", 100)
			p.Mu().Lock()
			p.Models[0].WeightHash = "old"
			p.WarmModels = []string{drainStateTestModel}
			p.CurrentModel = drainStateTestModel
			p.BackendCapacity = &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: drainStateTestModel, State: "idle"}}}
			index.index.Sync(p.ID, p, index.memberships[p.ID], p.Models)
			p.Mu().Unlock()
			r.SetModelCatalog([]production.CatalogEntry{
				{ID: drainStateTestModel, WeightHash: "current", ServingWeightHashes: []string{"old"}},
				{ID: "other", WeightHash: "other-hash"},
			})
			old := append([]protocol.ModelInfo(nil), p.Models...)
			generation := r.CommitProviderDrain(p, "drain")
			r.CompleteProviderDrain(p, "drain", generation)
			for _, validateOnly := range []bool{true, false} {
				_, _, _, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
					RequestID: "replace", DrainRequestID: "drain", ValidateOnly: validateOnly,
					Models: []protocol.ModelInfo{{ID: drainStateTestModel, WeightHash: tc.hash}},
				})
				if (err == nil) != tc.accepted {
					t.Fatalf("validateOnly=%t hash=%q accepted=%t: %v", validateOnly, tc.hash, tc.accepted, err)
				}
				if (validateOnly || !tc.accepted) && (!reflect.DeepEqual(p.Models, old) || !drains[p.ID].CanReplace("drain")) {
					t.Fatal("validation or rejection mutated inventory/drain readiness")
				}
				if !r.ProviderDraining(p.ID) {
					t.Fatal("replacement opened routing before acknowledgement and readiness")
				}
			}
			if tc.accepted && (len(p.WarmModels) == 1) != tc.keepWarm {
				t.Fatalf("warm state does not match retained weight identity: %+v", p.WarmModels)
			}
		})
	}
}

func TestReplaceProviderModelsRejectsRevisionRetiredAfterValidation(t *testing.T) {
	drains := make(providerDrainAuthorities)
	r := production.NewWithDependencies(testLogger(), production.Dependencies{ProviderDrains: drains.bind})
	p := registerDrainStateProvider(t, r, "session", 100)
	r.SetModelCatalog([]production.CatalogEntry{{ID: drainStateTestModel, WeightHash: "current", ServingWeightHashes: []string{"old"}}})
	generation := r.CommitProviderDrain(p, "drain")
	r.CompleteProviderDrain(p, "drain", generation)
	old := append([]protocol.ModelInfo(nil), p.Models...)
	msg := &protocol.ModelsReplaceMessage{
		RequestID: "replace", DrainRequestID: "drain", ValidateOnly: true,
		Models: []protocol.ModelInfo{{ID: drainStateTestModel, WeightHash: "old"}},
	}
	if _, _, _, err := r.ReplaceProviderModels(p, msg); err != nil {
		t.Fatalf("approved revision rejected during validation: %v", err)
	}
	r.SetModelCatalog([]production.CatalogEntry{{ID: drainStateTestModel, WeightHash: "current"}})
	msg.ValidateOnly = false
	if _, _, _, err := r.ReplaceProviderModels(p, msg); err == nil {
		t.Fatal("retired revision accepted after its approval was withdrawn")
	}
	if !reflect.DeepEqual(p.Models, old) || !drains[p.ID].CanReplace("drain") || !r.ProviderDraining(p.ID) {
		t.Fatal("retirement rejection mutated the drained inventory")
	}
}
