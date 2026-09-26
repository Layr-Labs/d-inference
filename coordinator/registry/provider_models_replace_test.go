package registry

import (
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestReplaceProviderModelsRejectsAtomicallyAndCanResumeOldSet(t *testing.T) {
	cases := []struct {
		name   string
		drain  string
		models []protocol.ModelInfo
		tools  []string
	}{
		{"wrong drain", "other", []protocol.ModelInfo{{ID: "new", WeightHash: "hash"}}, nil},
		{"empty", "drain", nil, nil},
		{"duplicate", "drain", []protocol.ModelInfo{{ID: "new", WeightHash: "hash"}, {ID: "new", WeightHash: "hash"}}, nil},
		{"unknown after valid", "drain", []protocol.ModelInfo{{ID: "new", WeightHash: "hash"}, {ID: "unknown"}}, nil},
		{"hash after valid", "drain", []protocol.ModelInfo{{ID: drainStateTestModel}, {ID: "new", WeightHash: "wrong"}}, nil},
		{"capability after valid", "drain", []protocol.ModelInfo{{ID: "new", WeightHash: "hash"}, {ID: "protected"}}, nil},
		{"unknown tool", "drain", []protocol.ModelInfo{{ID: "new", WeightHash: "hash"}}, []string{"other"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			p := registerDrainStateProvider(t, r, "session", 100)
			r.SetModelCatalog([]CatalogEntry{{ID: drainStateTestModel}, {ID: "new", WeightHash: "hash"}, {ID: "protected", RequiredProviderCapabilities: []string{"missing"}}})
			old := append([]protocol.ModelInfo(nil), p.Models...)
			generation := r.CommitProviderDrain(p, "drain")
			r.CompleteProviderDrain(p, "drain", generation)
			for _, validateOnly := range []bool{true, false} {
				_, _, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{RequestID: "replace", DrainRequestID: tc.drain, ValidateOnly: validateOnly, Models: tc.models, ToolConstraintProtocol: 1, ToolConstraintModels: tc.tools})
				if err == nil || !reflect.DeepEqual(p.Models, old) || !r.ProviderDraining(p.ID) || !p.drainReady || p.drainRequestID != "drain" || p.drainGeneration != generation {
					t.Fatalf("rejection mutated state: validateOnly=%v err=%v models=%+v", validateOnly, err, p.Models)
				}
			}
			_, _, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{RequestID: "rollback", DrainRequestID: "drain", Models: old})
			if err != nil || r.ProviderDraining(p.ID) {
				t.Fatalf("old inventory could not resume: %v", err)
			}
		})
	}
}

func TestReplaceProviderModelsPreservesSessionAndRemovesRoutingState(t *testing.T) {
	r := New(testLogger())
	p := registerDrainStateProvider(t, r, "session", 100)
	other := registerDrainStateProvider(t, r, "other", 1)
	r.SetModelCatalog([]CatalogEntry{{ID: drainStateTestModel}, {ID: "new"}})
	p.WarmModels = []string{drainStateTestModel}
	p.CurrentModel = drainStateTestModel
	p.BackendCapacity = &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: drainStateTestModel, State: "idle"}}}
	p.ToolConstraintProtocol = 1
	p.ToolConstraintModels = map[string]struct{}{drainStateTestModel: {}}
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{drainStateTestModel: {ModelID: drainStateTestModel}}
	p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{drainStateTestModel: {ModelID: drainStateTestModel}}
	p.TemplateHashes = map[string]string{drainStateTestModel: "template"}
	key := modelLoadKey{ProviderID: p.ID, ModelID: drainStateTestModel}
	r.pendingModelLoads[key] = time.Now().Add(time.Minute)
	r.pendingModelLoadStarted[key] = time.Now()
	trust, reputation, challenge, registered := p.TrustLevel, p.Reputation, p.LastChallengeVerified, p.registeredAt
	generation := r.CommitProviderDrain(p, "drain")
	r.CompleteProviderDrain(p, "drain", generation)
	oldModels := append([]protocol.ModelInfo(nil), p.Models...)
	oldRevision, oldCapacity := p.prefixCacheRevision, p.BackendCapacity
	loadUntil, loadStarted := r.pendingModelLoads[key], r.pendingModelLoadStarted[key]
	added, removed, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
		RequestID: "validate", DrainRequestID: "drain", ValidateOnly: true,
		Models: []protocol.ModelInfo{{ID: "new"}},
	})
	if err != nil || len(added) != 0 || len(removed) != 0 {
		t.Fatalf("validation failed or requested routing reconciliation: %v added=%v removed=%v", err, added, removed)
	}
	if !reflect.DeepEqual(p.Models, oldModels) || !reflect.DeepEqual(p.WarmModels, []string{drainStateTestModel}) || p.CurrentModel != drainStateTestModel || p.BackendCapacity != oldCapacity || p.BackendCapacity.Slots[0].Model != drainStateTestModel {
		t.Fatal("validation changed advertised or resident inventory")
	}
	if _, ok := p.ToolConstraintModels[drainStateTestModel]; !ok || p.ToolConstraintProtocol != 1 {
		t.Fatal("validation changed tool capabilities")
	}
	if _, ok := p.PrefixCacheV2Models[drainStateTestModel]; !ok {
		t.Fatal("validation invalidated disk cache evidence")
	}
	if _, ok := p.PrefixCacheMemoryModels[drainStateTestModel]; !ok || p.prefixCacheRevision != oldRevision || p.TemplateHashes[drainStateTestModel] != "template" {
		t.Fatal("validation invalidated memory cache or template evidence")
	}
	if r.pendingModelLoads[key] != loadUntil || r.pendingModelLoadStarted[key] != loadStarted {
		t.Fatal("validation changed pending model loads")
	}
	if r.GetProvider(p.ID) != p || p.TrustLevel != trust || !reflect.DeepEqual(p.Reputation, reputation) || p.LastChallengeVerified != challenge || p.registeredAt != registered {
		t.Fatal("validation reset live session/trust/reputation")
	}
	if !r.ProviderDraining(p.ID) || !p.drainReady || p.drainRequestID != "drain" || p.drainGeneration != generation {
		t.Fatal("validation consumed or reopened the settled drain")
	}
	if r.modelIndex.count(drainStateTestModel) != 2 || r.modelIndex.count("new") != 0 {
		t.Fatal("validation changed the routing index")
	}
	assertModelIndexConsistent(t, r)
	_, removed, err = r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{RequestID: "replace", DrainRequestID: "drain", Models: []protocol.ModelInfo{{ID: "new"}}})
	if err != nil || !reflect.DeepEqual(removed, []string{drainStateTestModel}) {
		t.Fatalf("replace: %v removed=%v", err, removed)
	}
	if r.GetProvider(p.ID) != p || p.TrustLevel != trust || !reflect.DeepEqual(p.Reputation, reputation) || p.LastChallengeVerified != challenge || p.registeredAt != registered {
		t.Fatal("replacement reset live session/trust/reputation")
	}
	if r.ProviderDraining(p.ID) || len(p.WarmModels) != 0 || p.CurrentModel != "" || len(p.BackendCapacity.Slots) != 0 || len(p.ToolConstraintModels) != 0 || len(p.PrefixCacheV2Models) != 0 || len(p.PrefixCacheMemoryModels) != 0 || len(p.TemplateHashes) != 0 {
		t.Fatal("replacement retained removed model state or drain")
	}
	if _, ok := r.pendingModelLoads[key]; ok {
		t.Fatal("removed model load remains pending")
	}
	// Delayed reports on the still-live socket must not resurrect removed slots.
	oldActive := drainStateTestModel
	r.MarkModelWarm(p.ID, oldActive)
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", ActiveModel: &oldActive, WarmModels: []string{oldActive},
		BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: oldActive, State: "idle"}}},
	})
	if len(p.WarmModels) != 0 || p.CurrentModel != "" || len(p.BackendCapacity.Slots) != 0 {
		t.Fatal("delayed heartbeat/load status restored removed inventory")
	}
	if selected := r.ReserveProvider(drainStateTestModel, drainStateRequest("old-model")); selected != other {
		t.Fatalf("removed model routed to %v, want other live provider", selected)
	}
	if selected := r.ReserveProvider("new", &PendingRequest{RequestID: "new-model", Model: "new", EstimatedPromptTokens: 100, RequestedMaxTokens: 64}); selected != p {
		t.Fatalf("new model not routable on same session: %v", selected)
	}
	assertModelIndexConsistent(t, r)
}

func TestReplaceProviderModelsRequiresSettledLatestLiveDrain(t *testing.T) {
	r := New(testLogger())
	p := registerDrainStateProvider(t, r, "session", 100)
	msg := &protocol.ModelsReplaceMessage{RequestID: "replace", DrainRequestID: "first", Models: p.Models}
	first := r.CommitProviderDrain(p, "first")
	for _, validateOnly := range []bool{true, false} {
		msg.ValidateOnly = validateOnly
		if _, _, err := r.ReplaceProviderModels(p, msg); err == nil {
			t.Fatalf("phase validateOnly=%v crossed unsettled terminal usage", validateOnly)
		}
	}
	second := r.CommitProviderDrain(p, "second")
	if r.CompleteProviderDrain(p, "first", first) {
		t.Fatal("superseded terminal barrier became ready")
	}
	r.CompleteProviderDrain(p, "second", second)
	for _, validateOnly := range []bool{true, false} {
		msg.ValidateOnly = validateOnly
		if _, _, err := r.ReplaceProviderModels(p, msg); err == nil {
			t.Fatalf("phase validateOnly=%v used an old receipt for a newer lifecycle drain", validateOnly)
		}
	}
	r.Disconnect(p.ID)
	fresh := registerDrainStateProvider(t, r, p.ID, 100)
	msg.DrainRequestID = "second"
	for _, validateOnly := range []bool{true, false} {
		msg.ValidateOnly = validateOnly
		if _, _, err := r.ReplaceProviderModels(p, msg); err == nil || r.GetProvider(p.ID) != fresh || r.ProviderDraining(fresh.ID) {
			t.Fatalf("phase validateOnly=%v changed a replacement session from a stale connection", validateOnly)
		}
	}
}

func TestReusedDrainIDCannotSettleNewerBarrier(t *testing.T) {
	r := New(testLogger())
	p := registerDrainStateProvider(t, r, "session", 100)
	first := r.CommitProviderDrain(p, "reused")
	second := r.CommitProviderDrain(p, "reused")
	if r.CompleteProviderDrain(p, "reused", first) {
		t.Fatal("earlier terminal snapshot settled a newer drain with the same wire ID")
	}
	msg := &protocol.ModelsReplaceMessage{RequestID: "validate", DrainRequestID: "reused", ValidateOnly: true, Models: p.Models}
	if _, _, err := r.ReplaceProviderModels(p, msg); err == nil {
		t.Fatal("validation crossed unsettled usage despite empty pending reservations")
	}
	if !r.CompleteProviderDrain(p, "reused", second) {
		t.Fatal("latest barrier could not settle")
	}
	if _, _, err := r.ReplaceProviderModels(p, msg); err != nil {
		t.Fatalf("settled validation failed: %v", err)
	}
	if !p.drainReady || !r.ProviderDraining(p.ID) {
		t.Fatal("validation consumed the latest settled barrier")
	}
}
