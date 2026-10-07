package registry_test

import (
	"reflect"
	"sort"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/modelindex"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type modelIndexFixture struct {
	reg         *production.Registry
	index       *modelindex.Index[*production.Provider]
	memberships map[string]*modelindex.Membership
	planner     *production.ReservationPlanner
}

func (f *modelIndexFixture) dependencies() production.Dependencies {
	return production.Dependencies{
		ModelAdvertisements: f.index,
		ModelMembership: func(id string) *modelindex.Membership {
			m := &modelindex.Membership{}
			f.memberships[id] = m
			return m
		},
		Reservations: func(p *production.ReservationPlanner) production.ReservationPreparation {
			f.planner = p
			return p
		},
	}
}

func newModelIndexFixture() *modelIndexFixture {
	f := &modelIndexFixture{index: &modelindex.Index[*production.Provider]{}, memberships: make(map[string]*modelindex.Membership)}
	f.reg = production.NewWithDependencies(testLogger(), f.dependencies())
	return f
}

type indexCandidateSource struct {
	index *modelindex.Index[*production.Provider]
	all   []*production.Provider
	brute bool
}

func (s *indexCandidateSource) AppendProviders(model string, dst []*production.Provider) []*production.Provider {
	if s.brute {
		return append(dst, s.all...)
	}
	return s.index.AppendProviders(model, dst)
}

func indexedBenchFleet(t *testing.T, gates *identitygate.Directory) (*benchFleet, *modelIndexFixture, *indexCandidateSource) {
	t.Helper()
	index := &modelindex.Index[*production.Provider]{}
	x := &modelIndexFixture{index: index, memberships: make(map[string]*modelindex.Membership)}
	source := &indexCandidateSource{index: index}
	deps := x.dependencies()
	deps.ModelCandidates = source
	deps.IdentityGates = gates
	f := buildBenchFleet(t, benchFleetProviders, benchFleetModels, deps)
	x.reg = f.reg
	for _, id := range f.ids {
		source.all = append(source.all, f.reg.GetProvider(id))
	}
	return f, x, source
}

type walkOutcome struct {
	pool                                    []string
	count, capacity, tooLarge, vision, ttft int
	bestTTFT                                float64
	quick                                   [3]int
	quickTTFT                               int64
	quickHas                                bool
	servable                                production.ServabilityVerdict
	aliasRoute, aliasStruct, aliasBuild     bool
}

func runWalks(r *production.Registry, planner *production.ReservationPlanner, model string, pr *production.PendingRequest, traits production.RequestTraits, vision bool) walkOutcome {
	var out walkOutcome
	scan := planner.ScanCandidates(model, pr, false)
	out.aliasRoute = planner.CanServeAlias(model, nil, pr.OwnerAccountID, pr.SelfRouteOnly, pr.PreferOwner, pr.FirstContentDeadline, traits, false)
	out.aliasStruct = planner.CanServeAlias(model, nil, pr.OwnerAccountID, pr.SelfRouteOnly, pr.PreferOwner, pr.FirstContentDeadline, traits, true)
	out.aliasBuild = planner.CanRouteBuild(model)
	for _, c := range scan.Candidates {
		out.pool = append(out.pool, c.ProviderID)
	}
	sort.Strings(out.pool)
	out.count, out.capacity, out.tooLarge = scan.CandidateCount, scan.CapacityRejections, scan.ModelTooLargeRejections
	out.vision, out.ttft, out.bestTTFT = scan.VisionRejections, scan.TTFTRejections, scan.BestTTFTMs
	c, cap_, tl, ttft, has := r.QuickCapacityCheckWithTTFTForRequest(model, 600, 512, traits, vision)
	out.quick, out.quickTTFT, out.quickHas = [3]int{c, cap_, tl}, int64(ttft), has
	out.servable = r.PredictServable(model, 600, 600, 512, 128_000, traits, vision)
	return out
}

func TestRoutingWalksIdenticalWithAndWithoutModelIndex(t *testing.T) {
	f, index, source := indexedBenchFleet(t, nil)
	shapes := []struct {
		name   string
		traits production.RequestTraits
		vision bool
		ttftMs float64
	}{
		{name: "plain"},
		{name: "tools", traits: production.RequestTraits{HasTools: true}},
		{name: "vision", vision: true},
		{name: "ttft-ceiling", ttftMs: 5_000},
	}
	for _, model := range []string{f.models[0], f.models[7], f.models[14], "not-a-model"} {
		for _, shape := range shapes {
			pr := benchPendingRequest(model, 0)
			pr.Traits, pr.RequiresVision, pr.MaxTTFTMs = shape.traits, shape.vision, shape.ttftMs
			source.brute = false
			withIndex := runWalks(f.reg, index.planner, model, pr, shape.traits, shape.vision)
			source.brute = true
			brute := runWalks(f.reg, index.planner, model, pr, shape.traits, shape.vision)
			source.brute = false
			if !reflect.DeepEqual(withIndex, brute) {
				t.Fatalf("%s/%s: walks differ\n index: %+v\n brute: %+v", model, shape.name, withIndex, brute)
			}
			if model != "not-a-model" && withIndex.count == 0 && shape.name == "plain" {
				t.Fatalf("%s: fixture produced no candidates", model)
			}
		}
	}
	index.assertConsistent(t)
}

func benchProviderAdvertises(f *benchFleet, i int, model string) bool {
	if f.models[i%benchFleetModels] == model {
		return true
	}
	if i%2 == 0 && f.models[(i+1)%benchFleetModels] == model {
		return true
	}
	return i%3 == 0 && f.models[(i+2)%benchFleetModels] == model
}

func TestRoutingWalksIdenticalWithFaultStateWithAndWithoutIndex(t *testing.T) {
	options := identitygate.DefaultOptions()
	options.HealthEjectionEnabled = func() bool { return true }
	gates := identitygate.New(testLogger(), &options)
	f, index, source := indexedBenchFleet(t, gates)
	model := f.models[0]
	var breakerID, ejectedID, cooledID string
	for i, id := range f.ids {
		if !benchProviderAdvertises(f, i, model) {
			if breakerID == "" {
				breakerID = id
			} else if ejectedID == "" {
				ejectedID = id
			}
		} else if cooledID == "" {
			cooledID = id
		}
		if breakerID != "" && ejectedID != "" && cooledID != "" {
			break
		}
	}
	for i := 0; i < providerBreakerConsecTrip; i++ {
		f.reg.RecordProviderOutcome(breakerID, false, 500, "internal error")
	}
	if !f.reg.ProviderBreakerOpen(breakerID) {
		t.Fatal("precondition: breaker open")
	}
	ejectedP := f.reg.GetProvider(ejectedID)
	ejectedP.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "SER-EJECT"})
	const sid = "serial:SER-EJECT"
	for i := 0; i < healthEjectionConsecTrip+1; i++ {
		f.reg.RecordProviderServeOutcome(sid, false, 500, "boom")
	}
	if !f.reg.HealthEjectionOpen(sid) {
		t.Fatal("precondition: identity ejected")
	}
	for i := 0; i < options.CapacityCooldown.Threshold+1; i++ {
		f.reg.RecordCapacityReject(cooledID, model)
	}
	if !gates.ViewForSession(nil, cooledID).CapacityCooled(model, benchPendingRequest(model, 0).FirstContentDeadline) {
		t.Fatal("precondition: advertiser capacity-cooled")
	}
	pr := benchPendingRequest(model, 0)
	scanWith := func(disabled bool) (production.CandidateScan, walkOutcome) {
		source.brute = disabled
		defer func() { source.brute = false }()
		scan := index.planner.ScanCandidates(model, pr, false)
		return scan, runWalks(f.reg, index.planner, model, pr, production.RequestTraits{}, false)
	}
	scanIdx, walkIdx := scanWith(false)
	scanBrute, walkBrute := scanWith(true)
	if !reflect.DeepEqual(walkIdx, walkBrute) {
		t.Fatalf("walks differ under fault state\n index: %+v\n brute: %+v", walkIdx, walkBrute)
	}
	if walkIdx.capacity == 0 {
		t.Fatal("the capacity-cooled advertiser must be counted as a capacity rejection")
	}
	for _, c := range scanIdx.Candidates {
		if c.ProviderID == cooledID || c.ProviderID == breakerID || c.ProviderID == ejectedID {
			t.Fatalf("faulted provider %s in the eligible pool", c.ProviderID)
		}
	}
	if scanIdx.BreakerRejected != 0 {
		t.Fatalf("indexed walk counted %d breaker rejections from non-advertisers", scanIdx.BreakerRejected)
	}
	if scanBrute.BreakerRejected != 2 {
		t.Fatalf("brute-force walk breakerRejected = %d, want 2 (breaker-open + ejected non-advertisers)", scanBrute.BreakerRejected)
	}
	poolIDs := map[string]struct{}{}
	for _, id := range walkIdx.pool {
		poolIDs[id] = struct{}{}
	}
	reserve := func(disabled bool) (*production.Provider, production.RoutingDecision) {
		source.brute = disabled
		defer func() { source.brute = false }()
		req := benchPendingRequest(model, 1)
		p, d := f.reg.ReserveProviderEx(model, req)
		if p != nil {
			p.RemovePending(req.RequestID)
		}
		return p, d
	}
	pIdx, dIdx := reserve(false)
	pBrute, dBrute := reserve(true)
	if pIdx == nil || pBrute == nil {
		t.Fatal("reservation must succeed with and without the index")
	}
	if _, ok := poolIDs[pIdx.ID]; !ok {
		t.Fatalf("indexed winner %s not in the eligible pool", pIdx.ID)
	}
	if _, ok := poolIDs[pBrute.ID]; !ok {
		t.Fatalf("brute-force winner %s not in the eligible pool", pBrute.ID)
	}
	tallies := func(d production.RoutingDecision) [6]float64 {
		return [6]float64{float64(d.CandidateCount), float64(d.CapacityRejections),
			float64(d.ModelTooLargeRejections), float64(d.VisionRejections),
			float64(d.TTFTRejections), d.BestTTFTMs}
	}
	if tallies(dIdx) != tallies(dBrute) {
		t.Fatalf("RoutingDecision tallies differ\n index: %+v\n brute: %+v", dIdx, dBrute)
	}
	index.assertConsistent(t)
}

func modelIndexRegister(t *testing.T, r *production.Registry, id string, models ...string) *production.Provider {
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

func (f *modelIndexFixture) count(model string) int {
	return len(f.index.AppendProviders(model, nil))
}

func (f *modelIndexFixture) assertConsistent(t testing.TB) {
	t.Helper()
	expected := make(map[string]map[string]*production.Provider)
	for _, snapshot := range f.reg.ListProviders() {
		p := f.reg.GetProvider(snapshot.ID)
		p.Mu().Lock()
		membership := f.memberships[p.ID]
		if !membership.Active() {
			t.Errorf("live provider %s is marked detached", p.ID)
		}
		if !membership.Matches(p.Models) {
			t.Errorf("provider %s baseline does not match models %v", p.ID, p.Models)
		}
		for _, m := range p.Models {
			set := expected[m.ID]
			if set == nil {
				set = make(map[string]*production.Provider)
				expected[m.ID] = set
			}
			set[p.ID] = p
		}
		p.Mu().Unlock()
	}
	for model, want := range expected {
		have := f.index.AppendProviders(model, nil)
		if len(have) != len(want) {
			t.Errorf("index[%s] has %d providers, brute force %d", model, len(have), len(want))
			continue
		}
		byID := make(map[string]*production.Provider)
		for _, p := range have {
			byID[p.ID] = p
		}
		for id, p := range want {
			if byID[id] != p {
				t.Errorf("index[%s] missing/mismatched provider %s", model, id)
			}
		}
	}
	for _, model := range f.index.Models() {
		if _, ok := expected[model]; !ok {
			t.Errorf("index has stale model %s with %d providers", model, f.count(model))
		}
	}
}

func TestModelIndexMatchesBruteForceAfterEveryMutation(t *testing.T) {
	f := newModelIndexFixture()
	r := f.reg
	r.SetModelCatalog(nil)
	f.assertConsistent(t)

	p1 := modelIndexRegister(t, r, "p1", "model-a", "model-b")
	f.assertConsistent(t)
	p2 := modelIndexRegister(t, r, "p2", "model-b")
	f.assertConsistent(t)
	if f.count("model-b") != 2 || f.count("model-a") != 1 {
		t.Fatalf("unexpected counts after register: a=%d b=%d", f.count("model-a"), f.count("model-b"))
	}

	// models_update: add.
	r.MergeProviderModels("p1", []protocol.ModelInfo{{ID: "model-c", ModelType: "chat"}})
	f.assertConsistent(t)
	if f.count("model-c") != 1 {
		t.Fatal("merge-added model not indexed")
	}

	// Weight-hash refresh: ids unchanged.
	r.UpdateModelWeightHashes("p1", map[string]string{"model-a": "hash-a"})
	f.assertConsistent(t)

	// Alias hard-swap: updating to the desired build drops the previous one.
	r.SetModelAliases(map[string]production.AliasTarget{"alias": {Desired: "model-d", Previous: "model-a"}})
	r.MergeProviderModels("p1", []protocol.ModelInfo{{ID: "model-d", ModelType: "chat"}})
	f.assertConsistent(t)
	if f.count("model-a") != 0 || f.count("model-d") != 1 {
		t.Fatalf("hard-swap not reflected: a=%d d=%d", f.count("model-a"), f.count("model-d"))
	}

	// Catalog change touches no advertisement.
	r.SetModelCatalog([]production.CatalogEntry{{ID: "model-b"}, {ID: "model-c"}})
	f.assertConsistent(t)

	// Untrust / recover: status is not advertisement; index unchanged.
	r.MarkUntrustedTransient("p1")
	f.assertConsistent(t)
	if f.count("model-b") != 2 {
		t.Fatal("untrust must not remove advertisement from the index")
	}

	// Disconnect removes every entry.
	r.Disconnect("p2")
	f.assertConsistent(t)
	if f.count("model-b") != 1 {
		t.Fatalf("disconnected provider still indexed: %d", f.count("model-b"))
	}

	// A models_update holding the old session must not revive it after detach.
	p2.Mu().Lock()
	p2.Models = append(p2.Models, protocol.ModelInfo{ID: "model-b"}, protocol.ModelInfo{ID: "model-z"})
	f.index.Sync(p2.ID, p2, f.memberships[p2.ID], p2.Models)
	p2.Mu().Unlock()
	f.assertConsistent(t)
	if f.count("model-z") != 0 {
		t.Fatal("detached provider was re-inserted by a racing sync")
	}

	// The real heartbeat repairs a forgotten advertisement update.
	p1.Mu().Lock()
	p1.Models = append(p1.Models, protocol.ModelInfo{ID: "model-e", ModelType: "chat"})
	p1.Mu().Unlock()
	if f.count("model-e") != 0 {
		t.Fatal("precondition: unsynced write must not be visible yet")
	}
	r.Heartbeat("p1", &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})
	f.assertConsistent(t)
	if f.count("model-e") != 1 {
		t.Fatal("heartbeat did not resync the index")
	}

	p1.Mu().Lock()
	allocs := testing.AllocsPerRun(100, func() { f.index.Sync(p1.ID, p1, f.memberships[p1.ID], p1.Models) })
	p1.Mu().Unlock()
	if allocs != 0 {
		t.Fatalf("no-op sync allocated %v", allocs)
	}
}

func TestModelIndexOffCatalogSelfRouteStillRoutes(t *testing.T) {
	f := newModelIndexFixture()
	r := f.reg
	r.SetModelCatalog([]production.CatalogEntry{{ID: "catalog-model"}})
	const local = "owner/local-model"
	mine := makeSchedulerProvider(t, r, "mine", local, 100)
	mine.Mu().Lock()
	mine.AccountID = "acct"
	mine.Mu().Unlock()
	pr := &production.PendingRequest{RequestID: "self", Model: local, RequestedMaxTokens: 16,
		OwnerAccountID: "acct", SelfRouteOnly: true}
	p, decision := r.ReserveProviderEx(local, pr)
	if p == nil {
		t.Fatalf("owner self-route to an off-catalog model failed through the index: %+v", decision)
	}
	p.RemovePending(pr.RequestID)
	pub := &production.PendingRequest{RequestID: "pub", Model: local, RequestedMaxTokens: 16}
	if p, _ := r.ReserveProviderEx(local, pub); p != nil {
		t.Fatal("public request routed to an off-catalog model")
	}
	f.assertConsistent(t)
}
