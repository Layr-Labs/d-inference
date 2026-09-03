package registry

import (
	"reflect"
	"sort"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
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

	// System-profiler routing context (#809), copied by value onto
	// RoutingDecision: the whole-registry Scanned / CandidateSetSize, the
	// per-gate tallies, the deterministic top-4 by (cost, id) over the
	// narrowed pool, and best-idle. The index prunes non-advertisers without
	// visiting them, so a wrong re-thread of these tallies would leave routing
	// correct and only ever show up here.
	scanned      int
	candidateSet int
	gates        [GateReasonCount]uint16
	top          [4]CandidateSummary
	bestIdle     CandidateSummary
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
	out.scanned, out.candidateSet, out.gates = scan.scanned, scan.candidateSetSize, scan.gateRejections
	out.top, out.bestIdle = scan.top, scan.bestIdle
	// Heartbeat age is read off the wall clock at snapshot time and drifts
	// between two walks; it is not what these comparisons pin.
	for i := range out.top {
		out.top[i].HBAgeMs = 0
	}
	out.bestIdle.HBAgeMs = 0
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
			// The profiler tallies are pinned in absolute terms as well: every
			// provider counts as scanned either way, the non-advertisers the index
			// never visits are tallied as GateNotServingModel, and the candidate
			// set is exactly the advertisers.
			advertisers := 0
			for i := range f.ids {
				if benchProviderAdvertises(f, i, model) {
					advertisers++
				}
			}
			if withIndex.scanned != benchFleetProviders || withIndex.candidateSet != advertisers ||
				int(withIndex.gates[GateNotServingModel]) != benchFleetProviders-advertisers {
				t.Fatalf("%s/%s: scanned=%d candidateSet=%d notServing=%d, want %d/%d/%d",
					model, shape.name, withIndex.scanned, withIndex.candidateSet, withIndex.gates[GateNotServingModel],
					benchFleetProviders, advertisers, benchFleetProviders-advertisers)
			}
		}
	}
	assertModelIndexConsistent(t, f.reg)
}

// benchProviderAdvertises reports whether bench provider i advertises model
// (mirrors buildBenchFleet's advertisement rule).
func benchProviderAdvertises(f *benchFleet, i int, model string) bool {
	if f.models[i%benchFleetModels] == model {
		return true
	}
	if i%2 == 0 && f.models[(i+1)%benchFleetModels] == model {
		return true
	}
	return i%3 == 0 && f.models[(i+2)%benchFleetModels] == model
}

// TestRoutingWalksIdenticalWithFaultStateWithAndWithoutIndex adds fault
// state the plain fixture lacks — a breaker-open NON-advertiser, a
// health-ejected NON-advertiser and a capacity-cooled ADVERTISER — and pins
// that the eligible pool, capacityRejections and every exposed
// RoutingDecision tally are identical with and without the index, and that a
// reservation succeeds from the same pool either way.
//
// The ONE intentional difference is scanCandidateScan.breakerRejected: the
// brute-force walk counts the two breaker/ejected providers even though they
// do not advertise the model, the indexed walk never visits them. That count
// is behavior-neutral: shouldBypassBreakerFailOpen only fires when the pool is
// empty AND no capacity/TTFT rejection exists, and the pass-2 rescan it
// triggers can only rescue an ADVERTISER rejected solely by breaker/ejection —
// which counts itself in both walks. The field is not part of RoutingDecision.
func TestRoutingWalksIdenticalWithFaultStateWithAndWithoutIndex(t *testing.T) {
	setHealthEjectionEnabledForTest(t, true)
	f := buildBenchFleet(t, benchFleetProviders, benchFleetModels)
	model := f.models[0]

	// Two non-advertisers of model: one breaker-open, one health-ejected.
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
	f.reg.mu.RLock()
	ejectedP := f.reg.providers[ejectedID]
	f.reg.mu.RUnlock()
	ejectedP.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "SER-EJECT"})
	const sid = "serial:SER-EJECT"
	for i := 0; i < healthEjectionConsecTrip+1; i++ {
		f.reg.RecordProviderServeOutcome(sid, false, 500, "boom")
	}
	if !f.reg.HealthEjectionOpen(sid) {
		t.Fatal("precondition: identity ejected")
	}
	for i := 0; i < f.reg.capacityCooldownCfg.Threshold+1; i++ {
		f.reg.RecordCapacityReject(cooledID, model)
	}
	f.reg.mu.RLock()
	cooled := f.reg.capacityCooldownActiveLocked(cooledID, model, benchPendingRequest(model, 0).FirstContentDeadline)
	f.reg.mu.RUnlock()
	if !cooled {
		t.Fatal("precondition: advertiser capacity-cooled")
	}

	pr := benchPendingRequest(model, 0)
	scanWith := func(disabled bool) (candidateScan, walkOutcome) {
		f.reg.modelIndexDisabled = disabled
		defer func() { f.reg.modelIndexDisabled = false }()
		f.reg.mu.RLock()
		scan := f.reg.scanCandidatesLocked(model, pr, false)
		f.reg.mu.RUnlock()
		return scan, runWalks(f.reg, model, pr, RequestTraits{}, false)
	}
	scanIdx, walkIdx := scanWith(false)
	scanBrute, walkBrute := scanWith(true)
	if !reflect.DeepEqual(walkIdx, walkBrute) {
		t.Fatalf("walks differ under fault state\n index: %+v\n brute: %+v", walkIdx, walkBrute)
	}
	if walkIdx.capacity == 0 {
		t.Fatal("the capacity-cooled advertiser must be counted as a capacity rejection")
	}
	for _, c := range scanIdx.pool {
		if c.provider.ID == cooledID || c.provider.ID == breakerID || c.provider.ID == ejectedID {
			t.Fatalf("faulted provider %s in the eligible pool", c.provider.ID)
		}
	}
	// The documented, behavior-neutral difference.
	if scanIdx.breakerRejected != 0 {
		t.Fatalf("indexed walk counted %d breaker rejections from non-advertisers", scanIdx.breakerRejected)
	}
	if scanBrute.breakerRejected != 2 {
		t.Fatalf("brute-force walk breakerRejected = %d, want 2 (breaker-open + ejected non-advertisers)", scanBrute.breakerRejected)
	}

	// Reservation: the same exposed RoutingDecision tallies and a winner from
	// the same pool either way (the winner itself is near-tie randomized).
	poolIDs := map[string]struct{}{}
	for _, id := range walkIdx.pool {
		poolIDs[id] = struct{}{}
	}
	reserve := func(disabled bool) (*Provider, RoutingDecision) {
		f.reg.modelIndexDisabled = disabled
		defer func() { f.reg.modelIndexDisabled = false }()
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
	tallies := func(d RoutingDecision) [6]float64 {
		return [6]float64{float64(d.CandidateCount), float64(d.CapacityRejections),
			float64(d.ModelTooLargeRejections), float64(d.VisionRejections),
			float64(d.TTFTRejections), d.BestTTFTMs}
	}
	if tallies(dIdx) != tallies(dBrute) {
		t.Fatalf("RoutingDecision tallies differ\n index: %+v\n brute: %+v", dIdx, dBrute)
	}
	// The #809 profiler fields ride on the same decision. Scanned,
	// CandidateSetSize, GateRejections and BestIdle are deterministic (only the
	// heartbeat age read off the clock is masked). The breaker-open and
	// ejected non-advertisers land on GateNotServingModel in BOTH walks — the
	// dispatch gate checks advertisement before the breaker/ejection gates —
	// which is exactly why the index's up-front tally of the providers it
	// never visits agrees with the brute-force walk.
	type profiled struct {
		scanned, candidateSet int
		gates                 [GateReasonCount]uint16
		bestIdle              CandidateSummary
	}
	profile := func(d RoutingDecision) profiled {
		p := profiled{d.Scanned, d.CandidateSetSize, d.GateRejections, d.BestIdle}
		p.bestIdle.HBAgeMs = 0
		return p
	}
	if pi, pb := profile(dIdx), profile(dBrute); pi != pb {
		t.Fatalf("RoutingDecision profiler fields differ\n index: %+v\n brute: %+v", pi, pb)
	}
	if dIdx.Scanned != benchFleetProviders || dIdx.GateRejections[GateNotServingModel] == 0 ||
		dIdx.GateRejections[GateCapacityCooldown] != 1 ||
		dIdx.GateRejections[GateBreaker] != 0 || dIdx.GateRejections[GateEjection] != 0 {
		t.Fatalf("profiler tallies off (want whole fleet scanned, non-advertisers on GateNotServingModel, one capacity-cooled advertiser): %+v", profile(dIdx))
	}
	// Top[0] is the near-tie randomized winner, so the arrays are compared
	// modulo the winner: every other slot must come from the deterministic
	// top-4 both walks agreed on above, and when both walks happened to pick
	// the same winner the arrays must match outright.
	natural := map[string]bool{}
	for _, c := range scanIdx.top {
		if c.Present {
			natural[c.ProviderID] = true
		}
	}
	for _, walk := range []struct {
		name   string
		d      RoutingDecision
		winner *Provider
	}{{"index", dIdx, pIdx}, {"brute", dBrute, pBrute}} {
		if !walk.d.Top[0].Present || walk.d.Top[0].ProviderID != walk.winner.ID {
			t.Fatalf("%s: Top[0] = %+v, want the winner %s", walk.name, walk.d.Top[0], walk.winner.ID)
		}
		for i := 1; i < len(walk.d.Top); i++ {
			if walk.d.Top[i].Present && !natural[walk.d.Top[i].ProviderID] {
				t.Fatalf("%s: Top[%d] = %s is not in the scan's top-4 %v", walk.name, i, walk.d.Top[i].ProviderID, natural)
			}
		}
	}
	if pIdx.ID == pBrute.ID {
		ti, tb := dIdx.Top, dBrute.Top
		for i := range ti {
			ti[i].HBAgeMs, tb[i].HBAgeMs = 0, 0
		}
		if ti != tb {
			t.Fatalf("same winner, Top differs\n index: %+v\n brute: %+v", ti, tb)
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
