package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	gemmaBuild     = "gemma-4-26b-qat-4bit"
	gemmaBuildOrg  = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	gemmaBuildSmol = "gemma-4-12b-qat-4bit"
	qwenBuild      = "qwen-3-32b"
)

// addModelToProvider appends an advertised model id to an already-registered
// provider (makeSchedulerProvider gives it exactly one). Mirrors how a real
// multi-model provider advertises its on-disk catalog.
func addAdvertisedModel(p *Provider, modelID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: modelID, ModelType: "chat", Quantization: "4bit"})
}

func TestParseDedicatedModels(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"gemma-4", []string{"gemma-4"}},
		{"gemma-4,Foo ", []string{"gemma-4", "foo"}},
		{" GEMMA-4 , Qwen ", []string{"gemma-4", "qwen"}},
		{"a, ,b", []string{"a", "b"}},
		{"", nil},
		{"   ", nil},
		{" , , ", nil},
	}
	for _, tc := range cases {
		got := ParseDedicatedModels(tc.in)
		if len(got) != len(tc.want) {
			t.Fatalf("ParseDedicatedModels(%q) = %v, want %v", tc.in, got, tc.want)
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Fatalf("ParseDedicatedModels(%q)[%d] = %q, want %q", tc.in, i, got[i], tc.want[i])
			}
		}
	}
}

func TestDedicatedPatternForLocked(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})

	reg.mu.RLock()
	defer reg.mu.RUnlock()

	matches := []string{gemmaBuild, gemmaBuildOrg, "GEMMA-4-foo", gemmaBuildSmol}
	for _, m := range matches {
		if pat, ok := reg.dedicatedPatternForLocked(m); !ok || pat != "gemma-4" {
			t.Fatalf("dedicatedPatternForLocked(%q) = (%q,%v), want (gemma-4,true)", m, pat, ok)
		}
	}
	for _, m := range []string{qwenBuild, "gpt-oss-20b", "gemma-3-27b"} {
		if _, ok := reg.dedicatedPatternForLocked(m); ok {
			t.Fatalf("dedicatedPatternForLocked(%q) matched, want no match", m)
		}
	}
}

func TestDedicatedPatternDisabledWhenUnset(t *testing.T) {
	reg := New(testLogger())
	reg.mu.RLock()
	defer reg.mu.RUnlock()
	if _, ok := reg.dedicatedPatternForLocked(gemmaBuild); ok {
		t.Fatalf("dedicatedPatternForLocked matched with no patterns configured")
	}
}

func TestSetDedicatedModelsNoneDisables(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	reg.SetDedicatedModels(nil) // explicit disable
	if reg.IsDedicatedModel(gemmaBuild) {
		t.Fatalf("IsDedicatedModel true after clearing patterns")
	}
	reg.SetDedicatedModels([]string{"  ", ""}) // all-blank also disables
	if reg.IsDedicatedModel(gemmaBuild) {
		t.Fatalf("IsDedicatedModel true after all-blank patterns")
	}
}

func TestProviderDedicatedToPatternLocked(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})

	check := func(p *Provider) bool {
		reg.mu.RLock()
		defer reg.mu.RUnlock()
		p.mu.Lock()
		defer p.mu.Unlock()
		return reg.providerDedicatedToPatternLocked(p, "gemma-4")
	}

	// Dedicated: single gemma-4 build.
	dedicated := makeSchedulerProvider(t, reg, "dedicated", gemmaBuild, 80)
	if !check(dedicated) {
		t.Fatal("single gemma-4 build provider should be dedicated")
	}

	// Dedicated: two gemma-4 builds.
	dedicated2 := makeSchedulerProvider(t, reg, "dedicated2", gemmaBuild, 80)
	addAdvertisedModel(dedicated2, gemmaBuildSmol)
	if !check(dedicated2) {
		t.Fatal("multiple gemma-4 builds provider should be dedicated")
	}

	// Mixed: gemma-4 + qwen.
	mixed := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 80)
	addAdvertisedModel(mixed, qwenBuild)
	if check(mixed) {
		t.Fatal("gemma-4 + qwen provider must NOT be dedicated")
	}

	// Qwen-only.
	qwen := makeSchedulerProvider(t, reg, "qwen", qwenBuild, 80)
	if check(qwen) {
		t.Fatal("qwen-only provider must NOT be dedicated to gemma-4")
	}

	// No advertised model → not dedicated.
	empty := makeSchedulerProvider(t, reg, "empty", gemmaBuild, 80)
	empty.mu.Lock()
	empty.Models = nil
	empty.mu.Unlock()
	if check(empty) {
		t.Fatal("provider advertising nothing must NOT be dedicated")
	}
}

func TestProviderDedicatedIgnoresNonCatalogModels(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	// Catalog allows only the gemma-4 build; a stale/unknown qwen advert is not
	// catalog-allowed and must NOT disqualify the box from being dedicated.
	reg.SetModelCatalog([]CatalogEntry{{ID: gemmaBuild}})

	p := makeSchedulerProvider(t, reg, "p", gemmaBuild, 80)
	addAdvertisedModel(p, qwenBuild) // not in catalog -> ignored

	reg.mu.RLock()
	defer reg.mu.RUnlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	if !reg.providerDedicatedToPatternLocked(p, "gemma-4") {
		t.Fatal("a non-catalog-allowed advert must not disqualify a dedicated box")
	}
}

func TestDedicatedRoutingSelectsOnlyDedicatedBox(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})

	// Mixed box is FASTER (higher TPS) but must be skipped for gemma-4.
	dedicated := makeSchedulerProvider(t, reg, "dedicated", gemmaBuild, 80)
	mixed := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 400)
	addAdvertisedModel(mixed, qwenBuild)

	req := &PendingRequest{RequestID: "g1", Model: gemmaBuild, EstimatedPromptTokens: 10, RequestedMaxTokens: 128}
	selected := reg.ReserveProvider(gemmaBuild, req)
	if selected == nil || selected.ID != dedicated.ID {
		t.Fatalf("gemma-4 routed to %#v, want dedicated %q", selected, dedicated.ID)
	}

	// Excluding the dedicated box yields NO candidate — never falls back to mixed.
	req2 := &PendingRequest{RequestID: "g2", Model: gemmaBuild, EstimatedPromptTokens: 10, RequestedMaxTokens: 128}
	selected2, decision := reg.ReserveProviderEx(gemmaBuild, req2, dedicated.ID)
	if selected2 != nil {
		t.Fatalf("gemma-4 fell back to %q after excluding dedicated, want nil", selected2.ID)
	}
	if decision.CandidateCount != 0 {
		t.Fatalf("candidate count = %d after excluding dedicated, want 0", decision.CandidateCount)
	}
}

func TestDedicatedRuleDoesNotAffectOtherModels(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})

	// Only a mixed box exists; a qwen request must still route to it.
	mixed := makeSchedulerProvider(t, reg, "mixed", qwenBuild, 200)
	addAdvertisedModel(mixed, gemmaBuild)

	req := &PendingRequest{RequestID: "q1", Model: qwenBuild, EstimatedPromptTokens: 10, RequestedMaxTokens: 128}
	selected := reg.ReserveProvider(qwenBuild, req)
	if selected == nil || selected.ID != mixed.ID {
		t.Fatalf("qwen routed to %#v, want mixed %q (rule must not touch non-dedicated models)", selected, mixed.ID)
	}
}

func TestDedicatedShedPreflightCountsOnlyDedicatedBoxes(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})

	// Only a mixed box serves gemma-4 → preflight sees zero candidates (the
	// coordinator says no / sheds to OpenRouter).
	mixed := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 200)
	addAdvertisedModel(mixed, qwenBuild)

	cc, _, _, _, _ := reg.QuickCapacityCheckWithTTFTForRequest(gemmaBuild, 500, 128, RequestTraits{}, false)
	if cc != 0 {
		t.Fatalf("preflight candidate count = %d with only a mixed box, want 0", cc)
	}

	// Add a dedicated box → capacity reappears.
	_ = makeSchedulerProvider(t, reg, "dedicated", gemmaBuild, 80)
	cc2, _, _, _, _ := reg.QuickCapacityCheckWithTTFTForRequest(gemmaBuild, 500, 128, RequestTraits{}, false)
	if cc2 < 1 {
		t.Fatalf("preflight candidate count = %d after adding a dedicated box, want >= 1", cc2)
	}
}

func TestDedicatedSelfRouteExempt(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})

	// Owner's own mixed machine: self-route must still reach it for gemma-4.
	mixed := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 200)
	addAdvertisedModel(mixed, qwenBuild)
	mixed.mu.Lock()
	mixed.AccountID = "acct-1"
	mixed.mu.Unlock()

	req := &PendingRequest{
		RequestID:             "self-1",
		Model:                 gemmaBuild,
		EstimatedPromptTokens: 10,
		RequestedMaxTokens:    128,
		SelfRouteOnly:         true,
		OwnerAccountID:        "acct-1",
	}
	selected := reg.ReserveProvider(gemmaBuild, req)
	if selected == nil || selected.ID != mixed.ID {
		t.Fatalf("self-route gemma-4 selected %#v, want owner's mixed box %q (rule must be exempt)", selected, mixed.ID)
	}
}

func TestDedicatedDisabledByDefaultRoutesToMixed(t *testing.T) {
	reg := New(testLogger()) // no SetDedicatedModels -> feature off
	mixed := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 200)
	addAdvertisedModel(mixed, qwenBuild)

	req := &PendingRequest{RequestID: "g1", Model: gemmaBuild, EstimatedPromptTokens: 10, RequestedMaxTokens: 128}
	selected := reg.ReserveProvider(gemmaBuild, req)
	if selected == nil || selected.ID != mixed.ID {
		t.Fatalf("with rule OFF, gemma-4 routed to %#v, want mixed %q", selected, mixed.ID)
	}
}

// The warm-pool / model-swap planner must honor the dedicated rule too —
// otherwise it pre-warms gemma-4 onto mixed boxes that routing will never use,
// and counts a warm mixed box as covering demand for a dedicated box.

func TestDedicatedWarmPoolSkipsMixedBox(t *testing.T) {
	reg := New(testLogger())
	now := time.Now()
	dedicated := makeSchedulerProvider(t, reg, "dedicated", gemmaBuild, 80)
	mixed := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 80)
	addAdvertisedModel(mixed, qwenBuild)

	warmCand := func(p *Provider) bool {
		reg.mu.RLock()
		defer reg.mu.RUnlock()
		p.mu.Lock()
		defer p.mu.Unlock()
		_, ok := reg.warmPoolCandidateLocked(p, gemmaBuild, now)
		return ok
	}
	loadCand := func(p *Provider) bool {
		reg.mu.RLock()
		defer reg.mu.RUnlock()
		_, ok := reg.modelLoadCandidatePendingLocked(p, gemmaBuild, now)
		return ok
	}

	// Baseline: with the rule OFF, the mixed box is a valid warm/load target.
	if !warmCand(mixed) || !loadCand(mixed) {
		t.Fatal("baseline (rule off): mixed box should be a warm/load candidate")
	}

	reg.SetDedicatedModels([]string{"gemma-4"})
	if !warmCand(dedicated) || !loadCand(dedicated) {
		t.Fatal("dedicated box should remain a warm/load candidate for gemma-4")
	}
	if warmCand(mixed) {
		t.Fatal("warm pool must NOT pre-warm gemma-4 onto a mixed box")
	}
	if loadCand(mixed) {
		t.Fatal("swap planner must NOT target a mixed box for gemma-4")
	}
}

func TestDedicatedWarmDetectionIgnoresMixedBox(t *testing.T) {
	reg := New(testLogger())
	now := time.Now()
	// makeSchedulerProvider gives a "running" gemma slot => warm.
	dedicated := makeSchedulerProvider(t, reg, "dedicated", gemmaBuild, 80)
	mixed := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 80)
	addAdvertisedModel(mixed, qwenBuild)

	warm := func(p *Provider) bool {
		reg.mu.RLock()
		defer reg.mu.RUnlock()
		p.mu.Lock()
		defer p.mu.Unlock()
		return reg.providerHasWarmModelLocked(p, gemmaBuild, now)
	}

	if !warm(mixed) {
		t.Fatal("baseline (rule off): a warm mixed box should count as warm")
	}
	reg.SetDedicatedModels([]string{"gemma-4"})
	if !warm(dedicated) {
		t.Fatal("a warm dedicated box should count as warm for gemma-4")
	}
	if warm(mixed) {
		t.Fatal("a warm mixed box must NOT count as warm for the dedicated model")
	}
}

// During a staged rollout, if a dedicated alias's Desired build is advertised
// only by a mixed-catalog box (not yet on a dedicated box) while the Previous
// build still has a dedicated box, alias resolution must fail over to Previous —
// not resolve to Desired and then 429 at dispatch. This is the alias-routability
// drift Codex flagged: providerCanRouteBuildLocked must apply the dedicated gate.
func TestDedicatedAliasFailsOverToPreviousOnDedicatedBox(t *testing.T) {
	desired := gemmaBuild      // would-be new build, only on a mixed box here
	previous := gemmaBuildSmol // stable build on a dedicated box

	setup := func(reg *Registry) {
		mixed := makeSchedulerProvider(t, reg, "mixed", desired, 200)
		addAdvertisedModel(mixed, qwenBuild) // Desired's only advertiser is mixed
		_ = makeSchedulerProvider(t, reg, "dedicated-prev", previous, 80)
		reg.SetModelAliases(map[string]AliasTarget{
			"gemma-4-26b": {Desired: desired, Previous: previous},
		})
	}

	// Baseline (rule OFF): Desired is routable on the mixed box → resolves Desired.
	off := New(testLogger())
	setup(off)
	if build, _, _ := off.ResolveModel("gemma-4-26b"); build != desired {
		t.Fatalf("rule off: resolved %q, want desired %q", build, desired)
	}

	// Rule ON: Desired only on a mixed box → not routable → fail over to the
	// dedicated Previous box instead of resolving Desired (which would 429).
	on := New(testLogger())
	on.SetDedicatedModels([]string{"gemma-4"})
	setup(on)
	if build, isAlias, ok := on.ResolveModel("gemma-4-26b"); !ok || !isAlias || build != previous {
		t.Fatalf("rule on: resolved %q (isAlias=%v ok=%v), want previous %q", build, isAlias, ok, previous)
	}
}

func TestIsDedicatedModel(t *testing.T) {
	reg := New(testLogger())
	if reg.IsDedicatedModel(gemmaBuild) {
		t.Fatal("IsDedicatedModel true with no patterns")
	}
	reg.SetDedicatedModels([]string{"gemma-4"})
	if !reg.IsDedicatedModel(gemmaBuild) || !reg.IsDedicatedModel(gemmaBuildOrg) {
		t.Fatal("IsDedicatedModel should be true for gemma-4 builds")
	}
	if reg.IsDedicatedModel(qwenBuild) {
		t.Fatal("IsDedicatedModel should be false for qwen")
	}
}

func TestHasProviderForModel(t *testing.T) {
	reg := New(testLogger())
	if reg.HasProviderForModel(gemmaBuild) {
		t.Fatal("HasProviderForModel true with empty fleet")
	}
	p := makeSchedulerProvider(t, reg, "p", gemmaBuild, 80)
	if !reg.HasProviderForModel(gemmaBuild) {
		t.Fatal("HasProviderForModel should be true when a provider advertises the model")
	}
	if reg.HasProviderForModel("totally-absent-model") {
		t.Fatal("HasProviderForModel should be false for an unadvertised model")
	}
	// Offline providers are excluded.
	p.mu.Lock()
	p.Status = StatusOffline
	p.mu.Unlock()
	if reg.HasProviderForModel(gemmaBuild) {
		t.Fatal("HasProviderForModel should exclude offline providers")
	}
}
