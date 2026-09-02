package registry

import (
	"reflect"
	"sort"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func modelIndexRegister(t *testing.T, r *Registry, id string, models ...string) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = msg.Models[:0]
	for _, m := range models {
		msg.Models = append(msg.Models, protocol.ModelInfo{ID: m, ModelType: "chat", Quantization: "4bit"})
	}
	p := r.Register(id, nil, msg)
	makeProviderRoutable(p)
	return p
}

// TestModelIndexMatchesBruteForceAfterEveryMutation drives every p.Models /
// r.providers mutation path the registry has and checks the index invariant
// after each one: register, models_update add, weight-hash refresh, alias
// hard-swap drop, catalog change, untrust/recover, disconnect, a
// models_update racing a disconnect, and the heartbeat backstop.
func TestModelIndexMatchesBruteForceAfterEveryMutation(t *testing.T) {
	r := New(testLogger())
	r.SetModelCatalog(nil)
	assertModelIndexConsistent(t, r)

	p1 := modelIndexRegister(t, r, "p1", "model-a", "model-b")
	assertModelIndexConsistent(t, r)
	p2 := modelIndexRegister(t, r, "p2", "model-b")
	assertModelIndexConsistent(t, r)
	if r.modelIndex.count("model-b") != 2 || r.modelIndex.count("model-a") != 1 {
		t.Fatalf("unexpected counts after register: a=%d b=%d", r.modelIndex.count("model-a"), r.modelIndex.count("model-b"))
	}

	// models_update: add.
	r.MergeProviderModels("p1", []protocol.ModelInfo{{ID: "model-c", ModelType: "chat"}})
	assertModelIndexConsistent(t, r)
	if r.modelIndex.count("model-c") != 1 {
		t.Fatal("merge-added model not indexed")
	}

	// Weight-hash refresh: ids unchanged.
	r.UpdateModelWeightHashes("p1", map[string]string{"model-a": "hash-a"})
	assertModelIndexConsistent(t, r)

	// Alias hard-swap: updating to the desired build drops the previous one.
	r.SetModelAliases(map[string]AliasTarget{"alias": {Desired: "model-d", Previous: "model-a"}})
	r.MergeProviderModels("p1", []protocol.ModelInfo{{ID: "model-d", ModelType: "chat"}})
	assertModelIndexConsistent(t, r)
	if r.modelIndex.count("model-a") != 0 || r.modelIndex.count("model-d") != 1 {
		t.Fatalf("hard-swap not reflected: a=%d d=%d", r.modelIndex.count("model-a"), r.modelIndex.count("model-d"))
	}

	// Catalog change touches no advertisement.
	r.SetModelCatalog([]CatalogEntry{{ID: "model-b"}, {ID: "model-c"}})
	assertModelIndexConsistent(t, r)

	// Untrust / recover: status is not advertisement; index unchanged.
	r.markUntrusted("p1", true)
	assertModelIndexConsistent(t, r)
	if r.modelIndex.count("model-b") != 2 {
		t.Fatal("untrust must not remove advertisement from the index")
	}

	// Disconnect removes every entry.
	r.Disconnect("p2")
	assertModelIndexConsistent(t, r)
	if r.modelIndex.count("model-b") != 1 {
		t.Fatalf("disconnected provider still indexed: %d", r.modelIndex.count("model-b"))
	}

	// A models_update that raced the disconnect (it already held the
	// *Provider) must not re-insert the dead session.
	p2.mu.Lock()
	p2.Models = append(p2.Models, protocol.ModelInfo{ID: "model-b"}, protocol.ModelInfo{ID: "model-z"})
	r.modelIndex.sync(p2)
	p2.mu.Unlock()
	assertModelIndexConsistent(t, r)
	if r.modelIndex.count("model-z") != 0 {
		t.Fatal("detached provider was re-inserted by a racing sync")
	}

	// Heartbeat backstop: a writer that forgets to sync is corrected on the
	// next heartbeat.
	p1.mu.Lock()
	p1.Models = append(p1.Models, protocol.ModelInfo{ID: "model-e", ModelType: "chat"})
	p1.mu.Unlock()
	if r.modelIndex.count("model-e") != 0 {
		t.Fatal("precondition: unsynced write must not be visible yet")
	}
	r.Heartbeat("p1", &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})
	assertModelIndexConsistent(t, r)
	if r.modelIndex.count("model-e") != 1 {
		t.Fatal("heartbeat did not resync the index")
	}

	// Index reads never allocate when the advertisement is unchanged.
	p1.mu.Lock()
	allocs := testing.AllocsPerRun(100, func() { r.modelIndex.sync(p1) })
	p1.mu.Unlock()
	if allocs != 0 {
		t.Fatalf("no-op sync allocated %v", allocs)
	}
}

type walkOutcome struct {
	pool        []string
	count       int
	capacity    int
	tooLarge    int
	vision      int
	ttft        int
	bestTTFT    float64
	quick       [3]int
	quickTTFT   int64
	quickHas    bool
	servable    ServabilityVerdict
	aliasRoute  bool
	aliasStruct bool
	aliasBuild  bool
	cacheCaps   []string
}

func runWalks(r *Registry, model string, pr *PendingRequest, traits RequestTraits, vision bool) walkOutcome {
	var out walkOutcome
	r.mu.RLock()
	scan := r.scanCandidatesLocked(model, pr, false)
	out.aliasRoute = r.anyProviderCanServeAliasWithTraitsLocked(model, nil, pr.OwnerAccountID, pr.SelfRouteOnly, pr.PreferOwner, pr.FirstContentDeadline, traits, false)
	out.aliasStruct = r.anyProviderCanServeAliasWithTraitsLocked(model, nil, pr.OwnerAccountID, pr.SelfRouteOnly, pr.PreferOwner, pr.FirstContentDeadline, traits, true)
	out.aliasBuild = r.anyProviderCanRouteBuildLocked(model)
	r.mu.RUnlock()
	for _, c := range scan.pool {
		out.pool = append(out.pool, c.provider.ID)
	}
	sort.Strings(out.pool)
	out.count, out.capacity, out.tooLarge = scan.candidateCount, scan.capacityRejections, scan.tooLargeRejections
	out.vision, out.ttft, out.bestTTFT = scan.visionRejections, scan.ttftRejections, scan.bestTTFTMs
	c, cap_, tl, ttft, has := r.QuickCapacityCheckWithTTFTForRequest(model, 600, 512, traits, vision)
	out.quick, out.quickTTFT, out.quickHas = [3]int{c, cap_, tl}, int64(ttft), has
	out.servable = r.PredictServable(model, 600, 600, 512, 128_000, traits, vision)
	for id := range r.prefixCacheV2CapabilitiesForModel(model) {
		out.cacheCaps = append(out.cacheCaps, id)
	}
	sort.Strings(out.cacheCaps)
	return out
}

// TestRoutingWalksIdenticalWithAndWithoutModelIndex runs every indexed walk
// over the fleet-scale fixture with the index on and off (brute-force over
// r.providers) for several request shapes and models, and requires identical
// eligible pools (as ID sets — near-tie spread randomizes the winner either
// way) and identical rejection tallies / verdicts.
func TestRoutingWalksIdenticalWithAndWithoutModelIndex(t *testing.T) {
	f := buildBenchFleet(t, benchFleetProviders, benchFleetModels)
	shapes := []struct {
		name   string
		traits RequestTraits
		vision bool
		ttftMs float64
	}{
		{name: "plain"},
		{name: "tools", traits: RequestTraits{HasTools: true}},
		{name: "vision", vision: true},
		{name: "ttft-ceiling", ttftMs: 5_000},
	}
	for _, model := range []string{f.models[0], f.models[7], f.models[14], "not-a-model"} {
		for _, shape := range shapes {
			pr := benchPendingRequest(model, 0)
			pr.Traits, pr.RequiresVision, pr.MaxTTFTMs = shape.traits, shape.vision, shape.ttftMs
			f.reg.modelIndexDisabled = false
			withIndex := runWalks(f.reg, model, pr, shape.traits, shape.vision)
			f.reg.modelIndexDisabled = true
			brute := runWalks(f.reg, model, pr, shape.traits, shape.vision)
			f.reg.modelIndexDisabled = false
			if !reflect.DeepEqual(withIndex, brute) {
				t.Fatalf("%s/%s: walks differ\n index: %+v\n brute: %+v", model, shape.name, withIndex, brute)
			}
			if model != "not-a-model" && withIndex.count == 0 && shape.name == "plain" {
				t.Fatalf("%s: fixture produced no candidates", model)
			}
		}
	}
	assertModelIndexConsistent(t, f.reg)
}

// TestModelIndexOffCatalogSelfRouteStillRoutes pins that the index is keyed on
// advertisement, not catalog: an owner's off-catalog local model (absent from
// the catalog) routes through the index exactly as through the full walk.
func TestModelIndexOffCatalogSelfRouteStillRoutes(t *testing.T) {
	r := New(testLogger())
	r.SetModelCatalog([]CatalogEntry{{ID: "catalog-model"}})
	const local = "owner/local-model"
	mine := makeSchedulerProvider(t, r, "mine", local, 100)
	mine.mu.Lock()
	mine.AccountID = "acct"
	mine.mu.Unlock()
	pr := &PendingRequest{RequestID: "self", Model: local, RequestedMaxTokens: 16,
		OwnerAccountID: "acct", SelfRouteOnly: true}
	p, decision := r.ReserveProviderEx(local, pr)
	if p == nil {
		t.Fatalf("owner self-route to an off-catalog model failed through the index: %+v", decision)
	}
	p.RemovePending(pr.RequestID)
	// Public routing to the same off-catalog model is still refused (catalog
	// gate), proving the index pruned nothing the gates would have allowed.
	pub := &PendingRequest{RequestID: "pub", Model: local, RequestedMaxTokens: 16}
	if p, _ := r.ReserveProviderEx(local, pub); p != nil {
		t.Fatal("public request routed to an off-catalog model")
	}
	assertModelIndexConsistent(t, r)
}
