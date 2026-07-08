package registry

import (
	"testing"
	"time"
)

// floorProvider registers a routable provider advertising BOTH gemma and
// gpt-oss builds (a mixed box) running the given binary version.
func floorProvider(t *testing.T, reg *Registry, id, version string) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, gemmaBuild, 30)
	addAdvertisedModel(p, gptossBuild)
	if version != "" {
		setProviderVersion(p, version)
	}
	return p
}

func TestParseModelVersionFloors(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want []ModelVersionFloor
	}{
		{"empty", "", nil},
		{"single", "gemma-4=0.7.5", []ModelVersionFloor{{Pattern: "gemma-4", Version: "0.7.5"}}},
		{"multi_with_spaces", " gemma-4 = 0.7.5 , gpt-oss = 0.8.0 ", []ModelVersionFloor{{Pattern: "gemma-4", Version: "0.7.5"}, {Pattern: "gpt-oss", Version: "0.8.0"}}},
		{"uppercase_pattern_lowered", "GEMMA-4=0.7.5", []ModelVersionFloor{{Pattern: "gemma-4", Version: "0.7.5"}}},
		// Malformed entries degrade to "no floor", never to a bad floor.
		{"bad_entries_skipped", "bogus,=0.7.5,gemma-4=,x", nil},
		{"mixed_valid_invalid", "bogus,gemma-4=0.7.5,=1", []ModelVersionFloor{{Pattern: "gemma-4", Version: "0.7.5"}}},
		// A NON-NUMERIC version must be dropped: CompareVersions treats an
		// unparseable segment as 0, so installing "gemma-4=foo" would fence
		// against an all-zero floor that every real version clears (the fence
		// silently defeated). Regression for the Codex finding.
		{"nonnumeric_version_dropped", "gemma-4=foo", nil},
		// A partially-numeric version ("0.7.x") would install 0.7.0 and let a
		// 0.7.4 box wrongly pass a 0.7.5-intended fence — dropped too.
		{"partial_numeric_version_dropped", "gemma-4=0.7.x", nil},
		// A valid entry survives alongside a dropped malformed one.
		{"valid_kept_bad_version_dropped", "gemma-4=0.7.5,gpt-oss=vNext", []ModelVersionFloor{{Pattern: "gemma-4", Version: "0.7.5"}}},
		// A leading v is tolerated (matches CompareVersions).
		{"v_prefix_ok", "gemma-4=v0.7.5", []ModelVersionFloor{{Pattern: "gemma-4", Version: "v0.7.5"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ParseModelVersionFloors(tc.raw)
			if len(got) != len(tc.want) {
				t.Fatalf("ParseModelVersionFloors(%q) = %v, want %v", tc.raw, got, tc.want)
			}
			for i := range tc.want {
				if got[i] != tc.want[i] {
					t.Fatalf("ParseModelVersionFloors(%q)[%d] = %v, want %v", tc.raw, i, got[i], tc.want[i])
				}
			}
		})
	}
}

// TestModelVersionFloorRoutingGate is the migration regression: with
// gemma-4=0.7.5 configured, gemma routes ONLY to >=0.7.5 providers — a 0.7.4
// box and a version-less box advertising the same build are excluded — while
// gpt-oss (no floor) still routes to every box. Fails without the routing-gate
// check (all three boxes would serve gemma).
func TestModelVersionFloorRoutingGate(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))

	floorProvider(t, reg, "old-box", "0.7.4")
	floorProvider(t, reg, "no-version-box", "")

	// Below-floor and version-less boxes must not serve the floored model...
	if p := findRoutableProvider(reg, gemmaBuild); p != nil {
		t.Fatalf("gemma routed to %s, want no provider (both boxes below the 0.7.5 floor)", p.ID)
	}
	// ...but still serve unfloored models (only gemma is fenced).
	if p := findRoutableProvider(reg, gptossBuild); p == nil {
		t.Fatalf("gpt-oss unroutable — the floor must fence only matching models")
	}

	// A >=floor box serves the floored model; the substring match covers any
	// build id containing the pattern (same semantics as dedicated models).
	floorProvider(t, reg, "new-box", "0.7.5")
	p := findRoutableProvider(reg, gemmaBuild)
	if p == nil || p.ID != "new-box" {
		t.Fatalf("gemma routed to %v, want new-box (the only >=0.7.5 provider)", p)
	}
}

// TestModelVersionFloorPreflightConsistency: the capacity preflight
// (QuickCapacityCheck) funnels through the same routing gate, so a below-floor
// box is structurally absent there too — no phantom capacity that routing then
// refuses.
func TestModelVersionFloorPreflightConsistency(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))
	floorProvider(t, reg, "old-box", "0.7.4")

	candidates, capacityRejects, tooLarge := reg.QuickCapacityCheck(gemmaBuild, 500, 128, RequestTraits{})
	if candidates != 0 || capacityRejects != 0 || tooLarge != 0 {
		t.Fatalf("preflight for floored gemma = (%d, %d, %d), want (0, 0, 0): a below-floor box is structural absence, not capacity", candidates, capacityRejects, tooLarge)
	}
	if candidates, _, _ := reg.QuickCapacityCheck(gptossBuild, 500, 128, RequestTraits{}); candidates != 1 {
		t.Fatalf("preflight for unfloored gpt-oss = %d candidates, want 1", candidates)
	}
}

// TestModelVersionFloorDisabledByDefault pins the flag-off contract: with no
// floors configured (the default), below-floor and version-less providers
// route exactly as today.
func TestModelVersionFloorDisabledByDefault(t *testing.T) {
	reg := New(testLogger())
	floorProvider(t, reg, "old-box", "0.7.4")
	if p := findRoutableProvider(reg, gemmaBuild); p == nil {
		t.Fatalf("gemma unroutable with no floors configured — empty env must be zero behavior change")
	}

	// Setting then clearing the floors restores the default entirely.
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))
	if p := findRoutableProvider(reg, gemmaBuild); p != nil {
		t.Fatalf("floor set: gemma routed to %s, want none", p.ID)
	}
	reg.SetModelVersionFloors(nil)
	if p := findRoutableProvider(reg, gemmaBuild); p == nil {
		t.Fatalf("floors cleared: gemma unroutable, want routable again")
	}
}

// TestModelVersionFloorWarmPoolCandidacy: the warm-pool candidate gate applies
// the same floor with its own disqualification reason, so the controller never
// pre-warms a box routing won't use — and the reason tally exposes why.
func TestModelVersionFloorWarmPoolCandidacy(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))

	oldBox := floorProvider(t, reg, "old-box", "0.7.4")
	newBox := floorProvider(t, reg, "new-box", "0.7.5")
	// Make both boxes COLD for gemma (no gemma slot in backend capacity) so they
	// are warm-pool candidates rather than already-warm providers.
	for _, p := range []*Provider{oldBox, newBox} {
		p.mu.Lock()
		p.BackendCapacity.Slots = nil
		p.mu.Unlock()
	}

	now := time.Now()
	reg.mu.RLock()
	oldBox.mu.Lock()
	_, oldReason := reg.warmPoolCandidateReasonLocked(oldBox, gemmaBuild, now)
	oldBox.mu.Unlock()
	newBox.mu.Lock()
	_, newReason := reg.warmPoolCandidateReasonLocked(newBox, gemmaBuild, now)
	newBox.mu.Unlock()
	reg.mu.RUnlock()

	if oldReason != warmColdBelowVersionFloor {
		t.Fatalf("below-floor cold box reason = %q, want %q", oldReason, warmColdBelowVersionFloor)
	}
	if newReason != warmColdEligible {
		t.Fatalf(">=floor cold box reason = %q, want eligible", newReason)
	}

	// The fleet snapshot surfaces the tally under the exported reason string, so
	// "why is eligible_cold 0" is a dashboard, not a grep.
	snap := reg.warmPoolFleetSnapshot(now)[gemmaBuild]
	if len(snap.eligibleCold) != 1 || snap.eligibleCold[0].providerID != "new-box" {
		t.Fatalf("eligibleCold = %+v, want exactly new-box", snap.eligibleCold)
	}
	if snap.coldDisq[warmColdBelowVersionFloor] != 1 {
		t.Fatalf("coldDisq = %v, want %q: 1", snap.coldDisq, warmColdBelowVersionFloor)
	}
}

// TestModelVersionFloorOwnedSummaryConsistency (review fix): the self-route
// preflight summary must apply the same per-model version floor as the
// dispatch gate — otherwise a below-floor OWNED box reads as "serves model",
// passes the self-route preflight, queues for up to 120s, and dies as
// machine_busy instead of failing fast with the real cause. Fails without the
// providerBelowModelVersionFloorLocked check in OwnedProviderSummary.
func TestModelVersionFloorOwnedSummaryConsistency(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))

	oldBox := floorProvider(t, reg, "owned-old", "0.7.4")
	oldBox.mu.Lock()
	oldBox.AccountID = "acct-1"
	oldBox.mu.Unlock()

	online, serves := reg.OwnedProviderSummary("acct-1", gemmaBuild, RequestTraits{}, false)
	if online != 1 || serves != 0 {
		t.Fatalf("below-floor owned box: OwnedProviderSummary = (online %d, serves %d), want (1, 0) — the summary must mirror the dispatch floor", online, serves)
	}
	// The floor is model-scoped: the same box still serves unfloored models.
	if _, serves := reg.OwnedProviderSummary("acct-1", gptossBuild, RequestTraits{}, false); serves != 1 {
		t.Fatalf("below-floor owned box: gpt-oss serves = %d, want 1 (only gemma is floored)", serves)
	}

	newBox := floorProvider(t, reg, "owned-new", "0.7.5")
	newBox.mu.Lock()
	newBox.AccountID = "acct-1"
	newBox.mu.Unlock()
	if online, serves := reg.OwnedProviderSummary("acct-1", gemmaBuild, RequestTraits{}, false); online != 2 || serves != 1 {
		t.Fatalf("with a >=floor owned box: OwnedProviderSummary = (online %d, serves %d), want (2, 1)", online, serves)
	}
}

// TestModelVersionFloorAliasResolutionFallsBackToPrevious (review fix): alias
// routability (providerCanRouteBuildLocked) must apply the same per-model
// version floor as the dispatch gate. Without it, a below-floor box advertising
// the alias's Desired build makes ResolveModel resolve to Desired, the
// candidate scan then finds ZERO eligible providers, and the request
// queues/dies against a build the fleet cannot serve — instead of falling back
// to the routable Previous build. Fails without the floor check in
// providerCanRouteBuildLocked.
func TestModelVersionFloorAliasResolutionFallsBackToPrevious(t *testing.T) {
	reg := New(testLogger())
	// aliasQAT contains "qat"; aliasFP8 does not — the floor fences ONLY the
	// Desired build.
	reg.SetModelVersionFloors(ParseModelVersionFloors("qat=0.7.5"))
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})

	// The ONLY box advertising Desired is below the floor; Previous has a
	// routable box.
	oldBox := registerProviderWithModel(reg, "old-desired-box", aliasQAT)
	makeProviderRoutable(oldBox)
	setProviderVersion(oldBox, "0.7.4")
	makeProviderRoutable(registerProviderWithModel(reg, "prev-box", aliasFP8))

	build, isAlias, ok := reg.ResolveModel("gemma-4-26b")
	if !ok || !isAlias || build != aliasFP8 {
		t.Fatalf("ResolveModel = (%q, %v, %v), want the Previous build %q — a below-floor box must not make Desired look routable", build, isAlias, ok, aliasFP8)
	}
	// RoutableProviderIDsForBuild shares the same predicate, so rollout/drop
	// measurement agrees with resolution: the floored Desired build has zero
	// routable providers.
	if ids := reg.RoutableProviderIDsForBuild(aliasQAT); len(ids) != 0 {
		t.Fatalf("RoutableProviderIDsForBuild(%q) = %v, want none (only provider is below floor)", aliasQAT, ids)
	}

	// Upgrading the box restores Desired-first resolution.
	setProviderVersion(oldBox, "0.7.5")
	if build, _, _ := reg.ResolveModel("gemma-4-26b"); build != aliasQAT {
		t.Fatalf("after upgrade: ResolveModel = %q, want Desired %q", build, aliasQAT)
	}
}

// TestModelVersionFloorSwapPlannerIgnoresBelowFloorWarmBox (review fix): the
// queue-driven swap path must mirror the floor. A below-floor box holding the
// model WARM must not suppress load planning (providerHasWarmModelLocked) —
// routing will never use its warm slot — and the planner must pick a >=floor
// cold box as the load_model target. Fails without the floor check in
// providerHasWarmModelLocked (no action is planned at all).
func TestModelVersionFloorSwapPlannerIgnoresBelowFloorWarmBox(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))

	// Below-floor box WARM for gemma (running slot from the fixture).
	floorProvider(t, reg, "old-warm-box", "0.7.4")
	// >=floor box COLD for gemma (advertises it, no slot).
	newBox := floorProvider(t, reg, "new-cold-box", "0.7.5")
	newBox.mu.Lock()
	newBox.BackendCapacity.Slots = nil
	newBox.mu.Unlock()

	actions := reg.planModelLoadActions([]string{gemmaBuild}, time.Now())
	if len(actions) != 1 || actions[0].providerID != "new-cold-box" || actions[0].modelID != gemmaBuild {
		t.Fatalf("planModelLoadActions = %+v, want exactly one load of %s onto new-cold-box — the below-floor warm box must not suppress it", actions, gemmaBuild)
	}
}

// TestModelVersionFloorSwapPlannerNeverTargetsBelowFloorBox (review fix): the
// load planner (modelLoadCandidatePendingLocked) must never send load_model to
// a below-floor box — routing would never use the resulting warm slot, so the
// load burns GPU memory while queued demand keeps waiting. Fails without the
// floor check in modelLoadCandidatePendingLocked (the idle below-floor box is
// picked as the target).
func TestModelVersionFloorSwapPlannerNeverTargetsBelowFloorBox(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))

	// The only box is idle, COLD for gemma, and below the floor.
	oldBox := floorProvider(t, reg, "old-cold-box", "0.7.4")
	oldBox.mu.Lock()
	oldBox.BackendCapacity.Slots = nil
	oldBox.mu.Unlock()

	if actions := reg.planModelLoadActions([]string{gemmaBuild}, time.Now()); len(actions) != 0 {
		t.Fatalf("planModelLoadActions = %+v, want none — a below-floor box must never receive load_model for a floored model", actions)
	}
	// The floor is model-scoped: the same box is still a valid target for an
	// unfloored model it advertises.
	if actions := reg.planModelLoadActions([]string{gptossBuild}, time.Now()); len(actions) != 1 || actions[0].providerID != "old-cold-box" {
		t.Fatalf("planModelLoadActions(gpt-oss) = %+v, want one load onto old-cold-box (only gemma is floored)", actions)
	}
}

// findModelCapacity returns the ModelCapacity snapshot entry for a build id.
func findModelCapacity(caps []ModelCapacity, modelID string) *ModelCapacity {
	for i := range caps {
		if caps[i].ModelID == modelID {
			return &caps[i]
		}
	}
	return nil
}

// TestModelVersionFloorCapacitySnapshot is the Codex regression: the public
// /v1/models/capacity feed must apply the per-model version floor too. A
// below-floor box advertising a floored model is unroutable, so counting its
// slot as a RoutableProvider would advertise capacity the preflight immediately
// 429s — luring upstream routers into undeliverable traffic. Fails without the
// floor gate inside ModelCapacitySnapshot (gemma RoutableProviders would be 2).
func TestModelVersionFloorCapacitySnapshot(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))
	floorProvider(t, reg, "old-box", "0.7.4") // below floor: advertises gemma + gpt-oss
	floorProvider(t, reg, "new-box", "0.7.5") // at floor

	caps := reg.ModelCapacitySnapshot()

	gemma := findModelCapacity(caps, gemmaBuild)
	if gemma == nil {
		t.Fatalf("gemma missing from capacity snapshot (the at-floor box should still count)")
	}
	if gemma.RoutableProviders != 1 {
		t.Fatalf("gemma RoutableProviders = %d, want 1 (only the >=0.7.5 box; the 0.7.4 box is floored out)", gemma.RoutableProviders)
	}
	// gpt-oss has no floor: both boxes count.
	gptoss := findModelCapacity(caps, gptossBuild)
	if gptoss == nil || gptoss.RoutableProviders != 2 {
		t.Fatalf("gpt-oss RoutableProviders = %v, want 2 (unfloored — both boxes)", gptoss)
	}
}

// TestModelVersionFloorDesiredModelsGate is the Codex regression: a below-floor
// box must NOT be steered toward the Desired build of a floored alias — routing
// will never use it there, so a desired_models command only makes it swap away
// from a still-usable previous build into one it cannot serve. Fails without the
// floor gate in DesiredModelsForProvider (the old box is told to converge to QAT).
func TestModelVersionFloorDesiredModelsGate(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))

	// Below-floor box advertising the previous build: must not be told to
	// converge to the floored desired build.
	old := registerProviderWithModel(reg, "p-old", aliasFP8)
	setProviderVersion(old, "0.7.4")
	if got := reg.DesiredModelsForProvider("p-old"); len(got) != 0 {
		t.Fatalf("below-floor box steered toward floored desired build, got %+v", got)
	}

	// At-floor box advertising the previous build: still told to converge.
	newp := registerProviderWithModel(reg, "p-new", aliasFP8)
	setProviderVersion(newp, "0.7.5")
	got := reg.DesiredModelsForProvider("p-new")
	if len(got) != 1 || got[0].DesiredBuild != aliasQAT {
		t.Fatalf("at-floor box should be told the desired build, got %+v", got)
	}
}
