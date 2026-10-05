package registry_test

import (
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/modelindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerdrain"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func markReplacementCapacityFresh(p *production.Provider, drain *providerdrain.Authority) {
	p.Mu().Lock()
	drain.AppliedCapacity("idle", 1)
	p.Mu().Unlock()
}

func TestReplaceProviderModelsInvalidatesOwnerLoadEvidenceForSameID(t *testing.T) {
	history := &measurements.History{}
	work := &warmplan.WorkHistory{}
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		Measurements: func(string) *measurements.History { return history },
		WarmHistory:  func(string) *warmplan.WorkHistory { return work },
	})
	r.SetModelCatalog([]production.CatalogEntry{{ID: drainStateTestModel}})
	p := registerDrainStateProvider(t, r, "session", 100)
	p.Mu().Lock()
	p.Models[0].EstimatedMemoryGB = 18.2
	p.CapacityModelIDs = []string{drainStateTestModel}
	p.CapacityAcceptedAt = time.Now()
	performanceCapacity := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
		Model: drainStateTestModel, State: "idle", Telemetry: &protocol.SlotTelemetry{},
		PerformanceMeasurements: localRateMeasurements(1000, 0),
	}}}
	// The prior-inventory proof is a direct local sample, not a transported frame.
	history.Reconcile(performanceCapacity, p.CapacityAcceptedAt, time.Now(), 0)
	warmCapacity := warmWorkCapacity("prior-inventory", 0, 0, 0, 0)
	warmCapacity.Slots[0].Model = drainStateTestModel
	work.Reconcile(warmCapacity, time.Now(), warmplan.NewState(), map[string]bool{drainStateTestModel: true}, forecast.PerformanceFreshness)
	p.BackendCapacity = &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{}}
	p.Mu().Unlock()
	generation := r.CommitProviderDrain(p, "drain")
	r.CompleteProviderDrain(p, "drain", generation)
	_, _, _, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
		RequestID: "replace", DrainRequestID: "drain",
		Models: []protocol.ModelInfo{{ID: drainStateTestModel, WeightHash: "new-hash", EstimatedMemoryGB: 3}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if p.CapacityModelIDs != nil || !p.CapacityAcceptedAt.IsZero() || p.BackendCapacity == nil {
		t.Fatal("same-ID replacement left owner load evidence fresh or disturbed routing capacity")
	}
	if history.Count() != 0 || work.Count() != 0 {
		t.Fatal("same-ID artifact replacement retained prior performance freshness or work baseline")
	}
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1, Slots: []protocol.BackendSlotCapacity{}},
	}) {
		t.Fatal("replacement heartbeat rejected")
	}
	if p.CapacityAcceptedAt.IsZero() || len(p.CapacityModelIDs) != 1 || p.CapacityModelIDs[0] != drainStateTestModel {
		t.Fatal("fresh applied heartbeat did not restore owner load evidence")
	}
}

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
		{"empty ID after valid", "drain", []protocol.ModelInfo{{ID: "new", WeightHash: "hash"}, {ID: ""}}, nil},
		{"hash after valid", "drain", []protocol.ModelInfo{{ID: drainStateTestModel}, {ID: "new", WeightHash: "wrong"}}, nil},
		{"hash after off-catalog", "drain", []protocol.ModelInfo{{ID: "local/model"}, {ID: "new", WeightHash: "wrong"}}, nil},
		{"missing hash after off-catalog", "drain", []protocol.ModelInfo{{ID: "local/model"}, {ID: "new"}}, nil},
		{"capability after valid", "drain", []protocol.ModelInfo{{ID: "new", WeightHash: "hash"}, {ID: "protected"}}, nil},
		{"off-catalog capability after valid", "drain", []protocol.ModelInfo{{ID: "new", WeightHash: "hash"}, {ID: production.Qwen38NAXModelID}}, nil},
		{"unknown tool", "drain", []protocol.ModelInfo{{ID: "new", WeightHash: "hash"}}, []string{"other"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			authorities := make(providerDrainAuthorities)
			r := production.NewWithDependencies(testLogger(), production.Dependencies{ProviderDrains: authorities.bind})
			p := registerDrainStateProvider(t, r, "session", 100)
			drain := authorities[p.ID]
			r.SetModelCatalog([]production.CatalogEntry{{ID: drainStateTestModel}, {ID: "new", WeightHash: "hash"}, {ID: "protected", RequiredProviderCapabilities: []string{"missing"}}})
			old := append([]protocol.ModelInfo(nil), p.Models...)
			generation := r.CommitProviderDrain(p, "drain")
			r.CompleteProviderDrain(p, "drain", generation)
			for _, validateOnly := range []bool{true, false} {
				_, _, _, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{RequestID: "replace", DrainRequestID: tc.drain, ValidateOnly: validateOnly, Models: tc.models, ToolConstraintProtocol: 1, ToolConstraintModels: tc.tools})
				if err == nil || !reflect.DeepEqual(p.Models, old) || !r.ProviderDraining(p.ID) || !drain.CanReplace("drain") || !r.CompleteProviderDrain(p, "drain", generation) {
					t.Fatalf("rejection mutated state: validateOnly=%v err=%v models=%+v", validateOnly, err, p.Models)
				}
			}
			_, _, receipt, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{RequestID: "rollback", DrainRequestID: "drain", Models: old})
			if err != nil || !r.ProviderDraining(p.ID) || !r.ConfirmProviderModelsReceipt(p, "rollback", receipt) {
				t.Fatalf("old inventory could not confirm receipt: %v", err)
			}
			markReplacementCapacityFresh(p, drain)
			_, _, resumed, _ := r.ResumeProviderModels(p, "rollback", "drain", 1)
			if !resumed || r.ProviderDraining(p.ID) {
				t.Fatalf("old inventory could not resume: %v", err)
			}
		})
	}
}

func TestReplaceProviderModelsAllowsOwnerOnlyOffCatalogInventory(t *testing.T) {
	for _, tc := range []struct {
		name        string
		privateOnly bool
		accountID   string
	}{
		{"shared", false, "owner"},
		{"private", true, "owner"},
		{"unlinked", false, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			index := &modelIndexFixture{index: &modelindex.Index[*production.Provider]{}, memberships: make(map[string]*modelindex.Membership)}
			authorities := make(providerDrainAuthorities)
			deps := index.dependencies()
			deps.ProviderDrains = authorities.bind
			r := production.NewWithDependencies(testLogger(), deps)
			index.reg = r
			r.SetModelCatalog([]production.CatalogEntry{{ID: "catalog/model", WeightHash: "catalog-hash"}})
			// Registration retains the old off-catalog model before owner linking.
			p := registerDrainStateProvider(t, r, "session", 100)
			drain := authorities[p.ID]
			p.PrivateOnly = tc.privateOnly
			setProviderAccount(p, tc.accountID)
			old := append([]protocol.ModelInfo(nil), p.Models...)
			models := append(append([]protocol.ModelInfo(nil), old...),
				protocol.ModelInfo{ID: "catalog/model", WeightHash: "catalog-hash"},
				protocol.ModelInfo{ID: "local/new", WeightHash: "local-hash"})
			trust, challenge := p.TrustLevel, p.LastChallengeVerified
			generation := r.CommitProviderDrain(p, "drain")
			r.CompleteProviderDrain(p, "drain", generation)
			msg := &protocol.ModelsReplaceMessage{
				RequestID: "validate", DrainRequestID: "drain", ValidateOnly: true, Models: models,
			}
			if _, _, _, err := r.ReplaceProviderModels(p, msg); err != nil {
				t.Fatalf("off-catalog preflight rejected: %v", err)
			}
			if !reflect.DeepEqual(p.Models, old) || !r.ProviderDraining(p.ID) || !drain.CanReplace("drain") {
				t.Fatal("preflight changed inventory or consumed the settled drain")
			}
			msg.RequestID, msg.ValidateOnly = "replace", false
			_, _, receipt, err := r.ReplaceProviderModels(p, msg)
			if err != nil || !r.ProviderDraining(p.ID) || !r.ConfirmProviderModelsReceipt(p, msg.RequestID, receipt) {
				t.Fatalf("off-catalog replacement rejected or resumed before its receipt: %v", err)
			}
			markReplacementCapacityFresh(p, drain)
			_, _, resumed, _ := r.ResumeProviderModels(p, msg.RequestID, msg.DrainRequestID, 1)
			if !resumed {
				t.Fatal("off-catalog replacement did not resume after provider readiness")
			}
			if !reflect.DeepEqual(p.Models, models) || r.ProviderDraining(p.ID) {
				t.Fatal("replacement did not install the complete set and resume")
			}
			if r.GetProvider(p.ID) != p || p.TrustLevel != trust || p.LastChallengeVerified != challenge {
				t.Fatal("replacement changed session trust")
			}
			if tc.accountID == "" {
				unlinked := &production.PendingRequest{RequestID: "unlinked", Model: "local/new", RequestedMaxTokens: 64, SelfRouteOnly: true, OwnerAccountID: "owner"}
				if selected := r.ReserveProvider(unlinked.Model, unlinked); selected != nil {
					t.Fatal("advertising a local model granted owner routing before linking")
				}
				setProviderAccount(p, "owner")
			}
			for _, model := range models {
				for _, preferOwner := range []bool{false, true} {
					req := &production.PendingRequest{
						RequestID: "owner", Model: model.ID, EstimatedPromptTokens: 100, RequestedMaxTokens: 64,
						OwnerAccountID: "owner", SelfRouteOnly: !preferOwner, PreferOwner: preferOwner,
					}
					selected, decision := r.ReserveProviderEx(model.ID, req)
					if selected != p {
						t.Fatalf("owner route for %q (prefer=%v) selected %v: %+v", model.ID, preferOwner, selected, decision)
					}
					p.RemovePending(req.RequestID)
				}
				public := &production.PendingRequest{RequestID: "public", Model: model.ID, EstimatedPromptTokens: 100, RequestedMaxTokens: 64}
				selected := r.ReserveProvider(model.ID, public)
				if model.ID == "catalog/model" && !tc.privateOnly {
					if selected != p {
						t.Fatal("catalog model lost public routing after replacement")
					}
					p.RemovePending(public.RequestID)
				} else if selected != nil {
					t.Fatalf("public route reached private or off-catalog model %q", model.ID)
				}
			}
			index.assertConsistent(t)
		})
	}
}

func TestReplaceProviderModelsPreservesSessionAndRemovesRoutingState(t *testing.T) {
	index := &modelIndexFixture{index: &modelindex.Index[*production.Provider]{}, memberships: make(map[string]*modelindex.Membership)}
	authorities := make(providerDrainAuthorities)
	loads := &pendingload.Ledger{}
	revisions := make(map[string]*cachepeer.Revision)
	origins := make(map[string]*connectiontime.Origin)
	originCreations := 0
	deps := index.dependencies()
	deps.ProviderDrains = authorities.bind
	deps.PendingLoads = loads
	deps.Cache.Revisions = func(id string) *cachepeer.Revision {
		revision := cachepeer.NewRevision()
		revisions[id] = revision
		return revision
	}
	deps.ConnectionOrigin = func(id string, at time.Time) *connectiontime.Origin {
		origin := connectiontime.New(at)
		origins[id] = origin
		originCreations++
		return origin
	}
	r := production.NewWithDependencies(testLogger(), deps)
	index.reg = r
	p := registerDrainStateProvider(t, r, "session", 100)
	other := registerDrainStateProvider(t, r, "other", 1)
	drain := authorities[p.ID]
	r.SetModelCatalog([]production.CatalogEntry{{ID: drainStateTestModel}, {ID: "new"}})
	p.WarmModels = []string{drainStateTestModel}
	p.CurrentModel = drainStateTestModel
	p.BackendCapacity = &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: drainStateTestModel, State: "idle"}}}
	p.ToolConstraintProtocol = 1
	p.ToolConstraintModels = map[string]struct{}{drainStateTestModel: {}}
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{drainStateTestModel: {ModelID: drainStateTestModel}}
	p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{drainStateTestModel: {ModelID: drainStateTestModel}}
	p.TemplateHashes = map[string]string{drainStateTestModel: "template"}
	key := pendingload.Key{ProviderID: p.ID, ModelID: drainStateTestModel}
	loads.Reserve(key, time.Now().Add(time.Minute), time.Now())
	trust, reputation, challenge := p.TrustLevel, p.Reputation, p.LastChallengeVerified
	frozenNow := time.Now()
	registered, registeredKnown := origins[p.ID].Age(frozenNow)
	registeredCreations := originCreations
	generation := r.CommitProviderDrain(p, "drain")
	r.CompleteProviderDrain(p, "drain", generation)
	oldModels := append([]protocol.ModelInfo(nil), p.Models...)
	oldRevision, oldCapacity := revisions[p.ID].Capture(), p.BackendCapacity
	load, _ := loads.Lookup(key)
	loadUntil, loadStarted := load.ExpiresAt, load.StartedAt
	added, removed, _, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
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
	if _, ok := p.PrefixCacheMemoryModels[drainStateTestModel]; !ok || !revisions[p.ID].Accepts(oldRevision) || p.TemplateHashes[drainStateTestModel] != "template" {
		t.Fatal("validation invalidated memory cache or template evidence")
	}
	if load, _ := loads.Lookup(key); load.ExpiresAt != loadUntil || load.StartedAt != loadStarted {
		t.Fatal("validation changed pending model loads")
	}
	age, known := origins[p.ID].Age(frozenNow)
	if r.GetProvider(p.ID) != p || p.TrustLevel != trust || !reflect.DeepEqual(p.Reputation, reputation) || p.LastChallengeVerified != challenge || age != registered || known != registeredKnown || originCreations != registeredCreations {
		t.Fatal("validation reset live session/trust/reputation")
	}
	if !r.ProviderDraining(p.ID) || !drain.CanReplace("drain") || !r.CompleteProviderDrain(p, "drain", generation) {
		t.Fatal("validation consumed or reopened the settled drain")
	}
	if index.count(drainStateTestModel) != 2 || index.count("new") != 0 {
		t.Fatal("validation changed the routing index")
	}
	index.assertConsistent(t)
	_, removed, receipt, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{RequestID: "replace", DrainRequestID: "drain", Models: []protocol.ModelInfo{{ID: "new"}}})
	if err != nil || !reflect.DeepEqual(removed, []string{drainStateTestModel}) {
		t.Fatalf("replace: %v removed=%v", err, removed)
	}
	if !r.ProviderDraining(p.ID) || !r.ConfirmProviderModelsReceipt(p, "replace", receipt) {
		t.Fatal("replacement must remain fenced until the exact receipt is written")
	}
	markReplacementCapacityFresh(p, drain)
	_, _, resumed, _ := r.ResumeProviderModels(p, "replace", "drain", 1)
	if !resumed {
		t.Fatal("replacement did not resume after provider readiness")
	}
	age, known = origins[p.ID].Age(frozenNow)
	if r.GetProvider(p.ID) != p || p.TrustLevel != trust || !reflect.DeepEqual(p.Reputation, reputation) || p.LastChallengeVerified != challenge || age != registered || known != registeredKnown || originCreations != registeredCreations {
		t.Fatal("replacement reset live session/trust/reputation")
	}
	if r.ProviderDraining(p.ID) || len(p.WarmModels) != 0 || p.CurrentModel != "" || len(p.BackendCapacity.Slots) != 0 || len(p.ToolConstraintModels) != 0 || len(p.PrefixCacheV2Models) != 0 || len(p.PrefixCacheMemoryModels) != 0 || len(p.TemplateHashes) != 0 {
		t.Fatal("replacement retained removed model state or drain")
	}
	if _, ok := loads.Lookup(key); ok {
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
	if selected := r.ReserveProvider("new", &production.PendingRequest{RequestID: "new-model", Model: "new", EstimatedPromptTokens: 100, RequestedMaxTokens: 64}); selected != p {
		t.Fatalf("new model not routable on same session: %v", selected)
	}
	index.assertConsistent(t)
}

func TestReusedDrainIDCannotSettleNewerBarrier(t *testing.T) {
	authorities := make(providerDrainAuthorities)
	r := production.NewWithDependencies(testLogger(), production.Dependencies{ProviderDrains: authorities.bind})
	p := registerDrainStateProvider(t, r, "session", 100)
	drain := authorities[p.ID]
	first := r.CommitProviderDrain(p, "reused")
	second := r.CommitProviderDrain(p, "reused")
	if r.CompleteProviderDrain(p, "reused", first) {
		t.Fatal("earlier terminal snapshot settled a newer drain with the same wire ID")
	}
	msg := &protocol.ModelsReplaceMessage{RequestID: "validate", DrainRequestID: "reused", ValidateOnly: true, Models: p.Models}
	if _, _, _, err := r.ReplaceProviderModels(p, msg); err == nil {
		t.Fatal("validation crossed unsettled usage despite empty pending reservations")
	}
	if !r.CompleteProviderDrain(p, "reused", second) {
		t.Fatal("latest barrier could not settle")
	}
	if _, _, _, err := r.ReplaceProviderModels(p, msg); err != nil {
		t.Fatalf("settled validation failed: %v", err)
	}
	if !drain.CanReplace("reused") || !r.ProviderDraining(p.ID) {
		t.Fatal("validation consumed the latest settled barrier")
	}
}

func TestReplaceProviderModelsRequiresSettledLatestLiveDrain(t *testing.T) {
	r := production.New(testLogger())
	p := registerDrainStateProvider(t, r, "session", 100)
	msg := &protocol.ModelsReplaceMessage{RequestID: "replace", DrainRequestID: "first", Models: p.Models}
	first := r.CommitProviderDrain(p, "first")
	for _, validateOnly := range []bool{true, false} {
		msg.ValidateOnly = validateOnly
		if _, _, _, err := r.ReplaceProviderModels(p, msg); err == nil {
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
		if _, _, _, err := r.ReplaceProviderModels(p, msg); err == nil {
			t.Fatalf("phase validateOnly=%v used an old receipt for a newer lifecycle drain", validateOnly)
		}
	}
	r.Disconnect(p.ID)
	fresh := registerDrainStateProvider(t, r, p.ID, 100)
	msg.DrainRequestID = "second"
	for _, validateOnly := range []bool{true, false} {
		msg.ValidateOnly = validateOnly
		if _, _, _, err := r.ReplaceProviderModels(p, msg); err == nil || r.GetProvider(p.ID) != fresh || r.ProviderDraining(fresh.ID) {
			t.Fatalf("phase validateOnly=%v changed a replacement session from a stale connection", validateOnly)
		}
	}
}
