package registry_test

import (
	"fmt"
	"math/rand"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// The pre-rewrite aggregation oracle retains the actual registered identities.
// Its original per-record loop remains intact: generated duplicate advertisements
// have identical hashes, so ServesCatalog is equivalent for each duplicate.
func referenceListModels(r *production.Registry, providers []*production.Provider, planner *production.ReservationPlanner) []production.AggregateModel {
	e := planner.PrepareEligibility()
	defer e.Close()
	type modelAgg struct {
		modelType     string
		quantization  string
		count         int
		attestedCount int
		highestTrust  production.TrustLevel
		secureEnclave bool
		sipEnabled    bool
		secureBoot    bool
	}
	agg := make(map[string]*modelAgg)
	for _, p := range providers {
		privateReady := e.PrivateText(p.ID, time.Now())
		p.Mu().Lock()
		status := p.Status
		trust := p.TrustLevel
		attested := p.Attested
		attestResult := p.AttestationResult
		privateOnly := p.PrivateOnly
		advertised := append([]protocol.ModelInfo(nil), p.Models...)
		p.Mu().Unlock()
		models := make([]protocol.ModelInfo, 0, len(advertised))
		for _, model := range advertised {
			if e.ServesCatalog(p.ID, model.ID) {
				models = append(models, model)
			}
		}
		if status == production.StatusOffline || status == production.StatusUntrusted {
			continue
		}
		if privateOnly {
			continue
		}
		if !r.TrustMeetsMinimum(trust) || !privateReady {
			continue
		}
		for _, m := range models {
			k := m.ID
			a, ok := agg[k]
			if !ok {
				a = &modelAgg{modelType: m.ModelType, quantization: m.Quantization, highestTrust: production.TrustNone}
				agg[k] = a
			}
			a.count++
			if trust != a.highestTrust && (&production.Registry{MinTrustLevel: a.highestTrust}).TrustMeetsMinimum(trust) {
				a.highestTrust = trust
			}
			if attested && attestResult != nil {
				a.attestedCount++
				a.secureEnclave = a.secureEnclave || attestResult.SecureEnclaveAvailable
				a.sipEnabled = a.sipEnabled || attestResult.SIPEnabled
				a.secureBoot = a.secureBoot || attestResult.SecureBootEnabled
			}
		}
	}
	models := make([]production.AggregateModel, 0, len(agg))
	for k, a := range agg {
		am := production.AggregateModel{
			ID: k, ModelType: a.modelType, Quantization: a.quantization,
			Providers: a.count, AttestedProviders: a.attestedCount, TrustLevel: a.highestTrust,
		}
		if a.attestedCount > 0 {
			am.Attestation = &production.AttestationSummary{SecureEnclave: a.secureEnclave, SIPEnabled: a.sipEnabled, SecureBoot: a.secureBoot}
		}
		models = append(models, am)
	}
	return models
}

func referencePublicProviderModels(providers []*production.Provider, planner *production.ReservationPlanner) map[string]production.PublicProviderModelSnapshot {
	e := planner.PrepareEligibility()
	defer e.Close()
	out := make(map[string]production.PublicProviderModelSnapshot, len(providers))
	for _, p := range providers {
		p.Mu().Lock()
		models := append([]protocol.ModelInfo(nil), p.Models...)
		current := p.CurrentModel
		p.Mu().Unlock()
		snapshot := production.PublicProviderModelSnapshot{Models: make([]string, 0, len(models))}
		for _, model := range models {
			if e.ServesCatalog(p.ID, model.ID) {
				snapshot.Models = append(snapshot.Models, model.ID)
			}
		}
		if current != "" && e.ServesCatalog(p.ID, current) {
			snapshot.CurrentModel = current
		}
		out[p.ID] = snapshot
	}
	return out
}

func equivRandomInventory(rng *rand.Rand) []protocol.ModelInfo {
	var models []protocol.ModelInfo
	for m := 0; m < equivCatalogModels; m++ {
		if rng.Intn(2) == 0 {
			continue
		}
		info := protocol.ModelInfo{ID: equivModelID(m), ModelType: "chat", Quantization: "4bit"}
		switch rng.Intn(3) {
		case 0:
			info.WeightHash = fmt.Sprintf("hash-%02d", m)
		case 1:
			info.WeightHash = "hash-mismatch"
		}
		if m%3 == 0 {
			info.ModelType = "vision"
			info.Quantization = "8bit"
		}
		models = append(models, info)
	}
	if rng.Intn(3) == 0 {
		models = append(models, protocol.ModelInfo{ID: "local/off-catalog", ModelType: "chat"})
	}
	if rng.Intn(5) == 0 && len(models) > 0 {
		models = append(models, models[0])
	}
	return models
}

func equivRandomizeProvider(rng *rand.Rand, p *production.Provider) {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	switch rng.Intn(5) {
	case 0:
		p.Status = production.StatusOffline
	case 1:
		p.Status = production.StatusUntrusted
	case 2:
		p.Status = production.StatusServing
	default:
		p.Status = production.StatusOnline
	}
	p.PrivateOnly = rng.Intn(6) == 0
	switch rng.Intn(4) {
	case 0:
		p.TrustLevel = production.TrustNone
	case 1:
		p.TrustLevel = production.TrustSelfSigned
	default:
		p.TrustLevel = production.TrustHardware
	}
	p.RuntimeVerified = rng.Intn(5) != 0
	p.RuntimeManifestChecked = rng.Intn(5) != 0
	p.ChallengeVerifiedSIP = rng.Intn(5) != 0
	p.LastChallengeVerified = time.Now()
	p.Attested = false
	p.AttestationResult = nil
	switch rng.Intn(4) {
	case 0, 1:
		p.Attested = true
		p.AttestationResult = &attestation.VerificationResult{
			Valid:                  true,
			SecureEnclaveAvailable: rng.Intn(2) == 0,
			SIPEnabled:             rng.Intn(2) == 0,
			SecureBootEnabled:      rng.Intn(2) == 0,
		}
	case 2:
		p.Attested = true
	}
	if rng.Intn(4) == 0 {
		p.PrivacyCapabilities = nil
	}
	switch rng.Intn(4) {
	case 0:
		if len(p.Models) > 0 {
			p.CurrentModel = p.Models[rng.Intn(len(p.Models))].ID
		}
	case 1:
		p.CurrentModel = "local/off-catalog"
	case 2:
		p.CurrentModel = "never/advertised"
	default:
		p.CurrentModel = ""
	}
}

func equivRegister(reg *production.Registry, rng *rand.Rand, id string) *production.Provider {
	msg := testRegisterMessage()
	msg.Models = equivRandomInventory(rng)
	p := reg.Register(id, nil, msg)
	equivRandomizeProvider(rng, p)
	return p
}

func sortAggregateModels(models []production.AggregateModel) []production.AggregateModel {
	sort.Slice(models, func(i, j int) bool { return models[i].ID < models[j].ID })
	return models
}

func assertAggregatesMatchReference(t *testing.T, reg *production.Registry, providers []*production.Provider, planner *production.ReservationPlanner, step string) {
	t.Helper()
	got := sortAggregateModels(reg.ListModels())
	want := sortAggregateModels(referenceListModels(reg, providers, planner))
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: ListModels diverged from the pre-rewrite oracle\n got: %+v\nwant: %+v", step, got, want)
	}
	gotP := reg.PublicProviderModels()
	wantP := referencePublicProviderModels(providers, planner)
	if !reflect.DeepEqual(gotP, wantP) {
		t.Fatalf("%s: PublicProviderModels diverged from the pre-rewrite oracle\n got: %+v\nwant: %+v", step, gotP, wantP)
	}
	for id, snap := range gotP {
		if snap.Models == nil {
			t.Fatalf("%s: provider %s has a nil Models view (stats JSON would emit null)", step, id)
		}
		if cap(snap.Models) != len(snap.Models) {
			t.Fatalf("%s: provider %s view has spare capacity %d > len %d (a consumer append could alias a neighbour)", step, id, cap(snap.Models), len(snap.Models))
		}
	}
}

func TestFleetAggregatesMatchReferenceAcrossMutations(t *testing.T) {
	for seed := int64(1); seed <= 6; seed++ {
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) {
			rng := rand.New(rand.NewSource(seed))
			var planner *production.ReservationPlanner
			reg := production.NewWithDependencies(testLogger(), production.Dependencies{
				Reservations: func(p *production.ReservationPlanner) production.ReservationPreparation {
					planner = p
					return p
				},
			})
			reg.SetModelCatalog(equivCatalog())
			var ids []string
			var providers []*production.Provider
			for i := 0; i < 60; i++ {
				id := fmt.Sprintf("equiv-%03d", i)
				providers = append(providers, equivRegister(reg, rng, id))
				ids = append(ids, id)
			}
			assertAggregatesMatchReference(t, reg, providers, planner, "initial")
			for _, id := range ids {
				if rng.Intn(3) != 0 {
					continue
				}
				status := "idle"
				if rng.Intn(2) == 0 {
					status = "serving"
				}
				hb := &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: status}
				if rng.Intn(2) == 0 {
					active := equivModelID(rng.Intn(equivCatalogModels))
					hb.ActiveModel = &active
					hb.WarmModels = []string{active}
				}
				reg.Heartbeat(id, hb)
			}
			assertAggregatesMatchReference(t, reg, providers, planner, "after heartbeats")
			for i := range ids {
				if rng.Intn(2) != 0 {
					continue
				}
				equivRandomizeProvider(rng, providers[i])
			}
			assertAggregatesMatchReference(t, reg, providers, planner, "after trust churn")
			catalog := equivCatalog()
			reg.SetModelCatalog(catalog[1:4])
			assertAggregatesMatchReference(t, reg, providers, planner, "after catalog shrink")
			for i := range catalog {
				catalog[i].WeightHash = "hash-mismatch"
			}
			reg.SetModelCatalog(catalog)
			assertAggregatesMatchReference(t, reg, providers, planner, "after catalog re-pin")
			reg.SetModelCatalog(nil)
			assertAggregatesMatchReference(t, reg, providers, planner, "after catalog disabled")
			reg.SetModelCatalog(equivCatalog())
			retained := providers[:0]
			for i, id := range ids {
				if i%3 == 0 {
					reg.Disconnect(id)
				} else {
					retained = append(retained, providers[i])
				}
			}
			providers = retained
			assertAggregatesMatchReference(t, reg, providers, planner, "after disconnects")
			for i := 0; i < 15; i++ {
				providers = append(providers, equivRegister(reg, rng, fmt.Sprintf("equiv-new-%03d", i)))
			}
			assertAggregatesMatchReference(t, reg, providers, planner, "after re-registrations")
			for _, id := range reg.ProviderIDs() {
				reg.Disconnect(id)
			}
			providers = nil
			assertAggregatesMatchReference(t, reg, providers, planner, "empty fleet")
			if got := reg.ListModels(); len(got) != 0 {
				t.Fatalf("empty fleet listed %d models", len(got))
			}
		})
	}
}

const equivCatalogModels = 6

func equivModelID(i int) string {
	return fmt.Sprintf("mlx-community/equiv-model-%02d-4bit", i)
}

func equivCatalog() []production.CatalogEntry {
	catalog := make([]production.CatalogEntry, 0, equivCatalogModels)
	for m := 0; m < equivCatalogModels; m++ {
		entry := production.CatalogEntry{ID: equivModelID(m), SizeGB: 8, MinRAMGB: 16}
		if m%2 == 0 {
			// Half the catalog pins a weight hash, so a mismatching
			// advertisement is filtered while a hashless one is not.
			entry.WeightHash = fmt.Sprintf("hash-%02d", m)
		}
		catalog = append(catalog, entry)
	}
	return catalog
}

// TestPublicProviderModelsViewsDoNotAlias pins the shared-backing-array
// contract: appending to one provider's view must never change another's.
func TestPublicProviderModelsViewsDoNotAlias(t *testing.T) {
	reg := production.New(testLogger())
	reg.SetModelCatalog(equivCatalog())
	for i := 0; i < 5; i++ {
		msg := testRegisterMessage()
		msg.Models = []protocol.ModelInfo{
			{ID: equivModelID(1), ModelType: "chat"},
			{ID: equivModelID(3), ModelType: "chat"},
		}
		reg.Register(fmt.Sprintf("alias-%d", i), nil, msg)
	}
	// One provider with nothing eligible: its view must be an empty, non-nil
	// slice even though it sits between populated neighbours in the array.
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: "local/off-catalog"}}
	reg.Register("alias-empty", nil, msg)

	snap := reg.PublicProviderModels()
	before := make(map[string][]string, len(snap))
	for id, s := range snap {
		// Non-nil copy even when empty, so DeepEqual compares contents only.
		before[id] = append(make([]string, 0, len(s.Models)), s.Models...)
	}
	if got := snap["alias-empty"].Models; got == nil || len(got) != 0 {
		t.Fatalf("empty provider view = %#v, want non-nil empty slice", got)
	}
	for id, s := range snap {
		grown := append(s.Models, "consumer/appended")
		if len(grown) != len(s.Models)+1 {
			t.Fatalf("append on %s did not grow the view", id)
		}
	}
	for id, s := range snap {
		if !reflect.DeepEqual(s.Models, before[id]) {
			t.Fatalf("view for %s changed after appending to a neighbour: %v -> %v", id, before[id], s.Models)
		}
	}
}
