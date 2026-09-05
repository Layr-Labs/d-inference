package registry

// Behavioral-equivalence tests for the allocation-free rewrites of the fleet
// aggregation walks. Each rewritten function is checked against a VERBATIM
// copy of its pre-rewrite body (the oracle) on randomized mixed fleets that
// toggle every provider-level gate and model-level filter independently, then
// again after every kind of mutation the registry sees in production
// (heartbeat status changes, trust changes, catalog hot swaps, disconnects,
// fresh registrations). The oracles are frozen on purpose: a future change to
// the live function that alters output on ANY fleet shape fails here.

import (
	"fmt"
	"math/rand"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// referenceListModels is ListModels exactly as it stood before the
// allocation-free rewrite (baseline commit 37d0f181c).
func referenceListModels(r *Registry) []AggregateModel {
	r.mu.RLock()
	defer r.mu.RUnlock()

	type modelAgg struct {
		modelType     string
		quantization  string
		count         int
		attestedCount int
		highestTrust  TrustLevel
		secureEnclave bool
		sipEnabled    bool
		secureBoot    bool
	}

	agg := make(map[string]*modelAgg)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		attested := p.Attested
		attestResult := p.AttestationResult
		privateReady := r.providerSupportsPrivateTextLocked(p)
		privateOnly := p.PrivateOnly
		models := make([]protocol.ModelInfo, 0, len(p.Models))
		for _, model := range p.Models {
			if r.providerModelAllowedByCatalogLocked(p, model) {
				models = append(models, model)
			}
		}
		p.mu.Unlock()

		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if privateOnly {
			continue
		}
		if !r.trustMeetsMinimum(trust) || !privateReady {
			continue
		}
		for _, m := range models {
			k := m.ID
			a, ok := agg[k]
			if !ok {
				a = &modelAgg{
					modelType:    m.ModelType,
					quantization: m.Quantization,
					highestTrust: TrustNone,
				}
				agg[k] = a
			}
			a.count++
			if trustRank(trust) > trustRank(a.highestTrust) {
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

	models := make([]AggregateModel, 0, len(agg))
	for k, a := range agg {
		am := AggregateModel{
			ID:                k,
			ModelType:         a.modelType,
			Quantization:      a.quantization,
			Providers:         a.count,
			AttestedProviders: a.attestedCount,
			TrustLevel:        a.highestTrust,
		}
		if a.attestedCount > 0 {
			am.Attestation = &AttestationSummary{
				SecureEnclave: a.secureEnclave,
				SIPEnabled:    a.sipEnabled,
				SecureBoot:    a.secureBoot,
			}
		}
		models = append(models, am)
	}
	return models
}

// referencePublicProviderModels is PublicProviderModels exactly as it stood
// before the single-backing-array rewrite (baseline commit 37d0f181c).
func referencePublicProviderModels(r *Registry) map[string]PublicProviderModelSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]PublicProviderModelSnapshot, len(r.providers))
	for id, p := range r.providers {
		p.mu.Lock()
		snapshot := PublicProviderModelSnapshot{
			Models: make([]string, 0, len(p.Models)),
		}
		for _, model := range p.Models {
			if r.providerModelAllowedByCatalogLocked(p, model) {
				snapshot.Models = append(snapshot.Models, model.ID)
			}
		}
		if p.CurrentModel != "" &&
			r.providerServesCatalogModelLocked(p, p.CurrentModel) {
			snapshot.CurrentModel = p.CurrentModel
		}
		p.mu.Unlock()
		out[id] = snapshot
	}
	return out
}

const equivCatalogModels = 6

func equivModelID(i int) string {
	return fmt.Sprintf("mlx-community/equiv-model-%02d-4bit", i)
}

func equivCatalog() []CatalogEntry {
	catalog := make([]CatalogEntry, 0, equivCatalogModels)
	for m := 0; m < equivCatalogModels; m++ {
		entry := CatalogEntry{ID: equivModelID(m), SizeGB: 8, MinRAMGB: 16}
		if m%2 == 0 {
			// Half the catalog pins a weight hash, so a mismatching
			// advertisement is filtered while a hashless one is not.
			entry.WeightHash = fmt.Sprintf("hash-%02d", m)
		}
		catalog = append(catalog, entry)
	}
	return catalog
}

// equivRandomInventory draws an advertised inventory that exercises every
// model-level filter: catalog hit/miss, pinned-hash match/mismatch/absent,
// off-catalog entries, varied metadata, and duplicate advertisements.
func equivRandomInventory(rng *rand.Rand) []protocol.ModelInfo {
	var models []protocol.ModelInfo
	for m := 0; m < equivCatalogModels; m++ {
		if rng.Intn(2) == 0 {
			continue
		}
		info := protocol.ModelInfo{ID: equivModelID(m), ModelType: "chat", Quantization: "4bit"}
		switch rng.Intn(3) {
		case 0:
			info.WeightHash = fmt.Sprintf("hash-%02d", m) // matches a pinned entry
		case 1:
			info.WeightHash = "hash-mismatch" // filtered on pinned entries only
		}
		// Metadata varies BY MODEL, never per provider: ListModels (before and
		// after the rewrite) takes ModelType/Quantization from whichever
		// eligible provider map iteration visits first, so two providers
		// disagreeing on a shared ID would make the oracle comparison flake on
		// a pre-existing non-determinism rather than on the rewrite.
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
		models = append(models, models[0]) // duplicate advertisement counts twice
	}
	return models
}

// equivRandomizeProvider toggles every provider-level gate the aggregations
// consult (status, private-only, trust floor, private-text readiness,
// attestation presence and flags, current model) independently at random.
func equivRandomizeProvider(rng *rand.Rand, p *Provider) {
	p.mu.Lock()
	defer p.mu.Unlock()
	switch rng.Intn(5) {
	case 0:
		p.Status = StatusOffline
	case 1:
		p.Status = StatusUntrusted
	case 2:
		p.Status = StatusServing
	default:
		p.Status = StatusOnline
	}
	p.PrivateOnly = rng.Intn(6) == 0
	switch rng.Intn(4) {
	case 0:
		p.TrustLevel = TrustNone
	case 1:
		p.TrustLevel = TrustSelfSigned
	default:
		p.TrustLevel = TrustHardware
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
		p.Attested = true // flag without a result must not count as attested
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

func equivRegister(reg *Registry, rng *rand.Rand, id string) *Provider {
	msg := testRegisterMessage()
	msg.Models = equivRandomInventory(rng)
	p := reg.Register(id, nil, msg)
	equivRandomizeProvider(rng, p)
	return p
}

func sortAggregateModels(models []AggregateModel) []AggregateModel {
	sort.Slice(models, func(i, j int) bool { return models[i].ID < models[j].ID })
	return models
}

// assertAggregatesMatchReference compares both live walks with their oracles.
// Output order of ListModels is map-random on both sides, so it is sorted.
func assertAggregatesMatchReference(t *testing.T, reg *Registry, step string) {
	t.Helper()
	got := sortAggregateModels(reg.ListModels())
	want := sortAggregateModels(referenceListModels(reg))
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: ListModels diverged from the pre-rewrite oracle\n got: %+v\nwant: %+v", step, got, want)
	}
	gotP := reg.PublicProviderModels()
	wantP := referencePublicProviderModels(reg)
	if !reflect.DeepEqual(gotP, wantP) {
		t.Fatalf("%s: PublicProviderModels diverged from the pre-rewrite oracle\n got: %+v\nwant: %+v", step, gotP, wantP)
	}
	for id, snap := range gotP {
		// /v1/stats serializes Models straight to JSON: [] must never become null.
		if snap.Models == nil {
			t.Fatalf("%s: provider %s has a nil Models view (stats JSON would emit null)", step, id)
		}
		if cap(snap.Models) != len(snap.Models) {
			t.Fatalf("%s: provider %s view has spare capacity %d > len %d (a consumer append could alias a neighbour)",
				step, id, cap(snap.Models), len(snap.Models))
		}
	}
}

// TestFleetAggregatesMatchReferenceAcrossMutations drives randomized fleets
// through every mutation class and checks both rewrites against their oracles
// after each one.
func TestFleetAggregatesMatchReferenceAcrossMutations(t *testing.T) {
	for seed := int64(1); seed <= 6; seed++ {
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) {
			rng := rand.New(rand.NewSource(seed))
			reg := New(testLogger())
			reg.SetModelCatalog(equivCatalog())

			var ids []string
			for i := 0; i < 60; i++ {
				id := fmt.Sprintf("equiv-%03d", i)
				equivRegister(reg, rng, id)
				ids = append(ids, id)
			}
			assertAggregatesMatchReference(t, reg, "initial")

			// Heartbeat-driven status changes (idle/serving) with and without
			// capacity, on a random third of the fleet.
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
			assertAggregatesMatchReference(t, reg, "after heartbeats")

			// Trust / attestation churn on a random half.
			for _, id := range ids {
				if rng.Intn(2) != 0 {
					continue
				}
				equivRandomizeProvider(rng, reg.GetProvider(id))
			}
			assertAggregatesMatchReference(t, reg, "after trust churn")

			// Catalog hot swaps: shrink, re-pin hashes, then disable filtering.
			catalog := equivCatalog()
			reg.SetModelCatalog(catalog[1:4])
			assertAggregatesMatchReference(t, reg, "after catalog shrink")
			for i := range catalog {
				catalog[i].WeightHash = "hash-mismatch"
			}
			reg.SetModelCatalog(catalog)
			assertAggregatesMatchReference(t, reg, "after catalog re-pin")
			reg.SetModelCatalog(nil)
			assertAggregatesMatchReference(t, reg, "after catalog disabled")
			reg.SetModelCatalog(equivCatalog())

			// Disconnect a third, register replacements.
			for i, id := range ids {
				if i%3 == 0 {
					reg.Disconnect(id)
				}
			}
			assertAggregatesMatchReference(t, reg, "after disconnects")
			for i := 0; i < 15; i++ {
				equivRegister(reg, rng, fmt.Sprintf("equiv-new-%03d", i))
			}
			assertAggregatesMatchReference(t, reg, "after re-registrations")

			// Empty fleet.
			for _, id := range reg.ProviderIDs() {
				reg.Disconnect(id)
			}
			assertAggregatesMatchReference(t, reg, "empty fleet")
			if got := reg.ListModels(); len(got) != 0 {
				t.Fatalf("empty fleet listed %d models", len(got))
			}
		})
	}
}

// TestPublicProviderModelsViewsDoNotAlias pins the shared-backing-array
// contract: appending to one provider's view must never change another's.
func TestPublicProviderModelsViewsDoNotAlias(t *testing.T) {
	reg := New(testLogger())
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
