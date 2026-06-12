package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func setProviderVersion(p *Provider, v string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.Version = v
}

func boolPtr(b bool) *bool { return &b }

func TestCompareVersions(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		{"0.6.3", "0.6.3", 0},
		{"0.6.2", "0.6.3", -1},
		{"0.6.4", "0.6.3", 1},
		// Numeric compare, not lexicographic: "10" > "3".
		{"0.6.10", "0.6.3", 1},
		{"0.6.3", "0.6.10", -1},
		// "v"/"V" prefix tolerated.
		{"v0.6.3", "0.6.3", 0},
		{"V0.6.4", "v0.6.3", 1},
		// Different segment counts: missing segments compare as 0.
		{"0.6", "0.6.0", 0},
		{"0.6", "0.6.1", -1},
		{"1", "0.9.9", 1},
		{"0.7", "0.6.99", 1},
		// Empty parses as all-zeros: below any real floor.
		{"", "0.6.3", -1},
		{"", "", 0},
		// Unparseable segments compare as 0.
		{"garbage", "0.6.3", -1},
		{"garbage", "", 0},
		{"0.garbage.3", "0.0.3", 0},
		// A suffixed segment ("3-rc1") is unparseable → 0, so it sorts below
		// the plain release (fail-closed for tool routing).
		{"0.6.3-rc1", "0.6.3", -1},
		// Negative segments clamp to 0.
		{"0.-6.3", "0.0.3", 0},
		// Whitespace tolerated.
		{" 0.6.3 ", "0.6.3", 0},
	}
	for _, tc := range tests {
		if got := CompareVersions(tc.a, tc.b); got != tc.want {
			t.Errorf("CompareVersions(%q, %q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
		// Antisymmetry: swapping operands must negate the result.
		if got := CompareVersions(tc.b, tc.a); got != -tc.want {
			t.Errorf("CompareVersions(%q, %q) = %d, want %d", tc.b, tc.a, got, -tc.want)
		}
	}
}

func TestProviderMeetsTraitFloors(t *testing.T) {
	tests := []struct {
		name    string
		version string
		traits  RequestTraits
		want    bool
	}{
		{"no traits, ancient version", "0.4.7", RequestTraits{}, true},
		{"no traits, empty version", "", RequestTraits{}, true},
		{"tools exactly at floor", "0.6.3", RequestTraits{HasTools: true}, true},
		{"tools above floor", "0.6.4", RequestTraits{HasTools: true}, true},
		{"tools far above floor (numeric compare)", "0.6.10", RequestTraits{HasTools: true}, true},
		{"tools above floor with v prefix", "v0.6.4", RequestTraits{HasTools: true}, true},
		{"tools below floor", "0.6.2", RequestTraits{HasTools: true}, false},
		{"tools old fleet version", "0.5.16", RequestTraits{HasTools: true}, false},
		{"tools empty version is below any floor", "", RequestTraits{HasTools: true}, false},
		{"tools garbage version is below floor", "garbage", RequestTraits{HasTools: true}, false},
		{"avoid-version alone is not a floor", "0.4.7", RequestTraits{AvoidVersion: "0.4.7"}, true},
	}
	r := New(testLogger())
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := &Provider{ID: "p", Version: tc.version}
			r.mu.RLock()
			p.mu.Lock()
			got := r.providerMeetsTraitFloorsLocked(p, tc.traits)
			p.mu.Unlock()
			r.mu.RUnlock()
			if got != tc.want {
				t.Fatalf("providerMeetsTraitFloorsLocked(version=%q, traits=%+v) = %v, want %v",
					tc.version, tc.traits, got, tc.want)
			}
		})
	}
}

func TestProviderEligibleForTraitsTemplateRenderGate(t *testing.T) {
	const model = "gemma-4-26b"
	tests := []struct {
		name     string
		renderOK *bool
		traits   RequestTraits
		want     bool
	}{
		{"nil verdict allowed (pre-0.6.5 provider, no opinion)", nil, RequestTraits{HasTools: true}, true},
		{"render ok allowed", boolPtr(true), RequestTraits{HasTools: true}, true},
		{"render broken excluded for tool requests", boolPtr(false), RequestTraits{HasTools: true}, false},
		// A crashing chat template breaks EVERY request shape for the pair, not
		// just tools — the render-broken gate fences plain requests too.
		{"render broken also excluded without tools", boolPtr(false), RequestTraits{}, false},
		// nil/true verdicts impose no gate on plain requests.
		{"render ok allowed without tools", boolPtr(true), RequestTraits{}, true},
		{"nil verdict allowed without tools", nil, RequestTraits{}, true},
	}
	r := New(testLogger())
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := &Provider{
				ID:      "p",
				Version: "0.6.5", // above the tools floor, so only the render gate decides
				Models:  []protocol.ModelInfo{{ID: model, TemplateRenderOK: tc.renderOK}},
			}
			r.mu.RLock()
			p.mu.Lock()
			got := r.providerEligibleForTraitsLocked(p, model, tc.traits)
			p.mu.Unlock()
			r.mu.RUnlock()
			if got != tc.want {
				t.Fatalf("providerEligibleForTraitsLocked(renderOK=%v, traits=%+v) = %v, want %v",
					tc.renderOK, tc.traits, got, tc.want)
			}
		})
	}
}

// The render verdict is per-model: a broken template on one build must not
// exclude the provider's other builds from tool requests.
func TestTemplateRenderGateScopedToModel(t *testing.T) {
	r := New(testLogger())
	p := &Provider{
		ID:      "p",
		Version: "0.6.5",
		Models: []protocol.ModelInfo{
			{ID: "broken-model", TemplateRenderOK: boolPtr(false)},
			{ID: "healthy-model", TemplateRenderOK: boolPtr(true)},
			{ID: "legacy-model"}, // nil verdict
		},
	}
	traits := RequestTraits{HasTools: true}
	r.mu.RLock()
	p.mu.Lock()
	brokenOK := r.providerEligibleForTraitsLocked(p, "broken-model", traits)
	healthyOK := r.providerEligibleForTraitsLocked(p, "healthy-model", traits)
	legacyOK := r.providerEligibleForTraitsLocked(p, "legacy-model", traits)
	p.mu.Unlock()
	r.mu.RUnlock()
	if brokenOK {
		t.Fatal("broken-model must be excluded from tool requests")
	}
	if !healthyOK || !legacyOK {
		t.Fatalf("healthy=%v legacy=%v: render verdict must be scoped to the broken model only", healthyOK, legacyOK)
	}
}

// Scheduler integration: a tool-bearing request must skip providers below the
// tools version floor, while a plain request still uses them.
func TestReserveProviderExEnforcesToolsVersionFloor(t *testing.T) {
	reg := New(testLogger())
	model := "tools-floor-model"
	old := makeSchedulerProvider(t, reg, "old-binary", model, 200)
	newer := makeSchedulerProvider(t, reg, "new-binary", model, 50)
	setProviderVersion(old, "0.6.2")
	setProviderVersion(newer, "0.6.4")

	toolReq := &PendingRequest{
		RequestID:          "r-tools",
		Model:              model,
		RequestedMaxTokens: 128,
		Traits:             RequestTraits{HasTools: true},
	}
	selected, decision := reg.ReserveProviderEx(model, toolReq)
	if selected == nil || selected.ID != newer.ID {
		t.Fatalf("tool request selected %v, want %q (the only provider at/above the 0.6.3 floor)", selected, newer.ID)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("CandidateCount=%d, want 1 (below-floor provider excluded)", decision.CandidateCount)
	}
	newer.RemovePending("r-tools")

	// Without tools, the old binary is still a candidate.
	plain := &PendingRequest{RequestID: "r-plain", Model: model, RequestedMaxTokens: 128}
	selected, decision = reg.ReserveProviderEx(model, plain)
	if selected == nil {
		t.Fatal("plain request should route")
	}
	if decision.CandidateCount != 2 {
		t.Fatalf("CandidateCount=%d, want 2 (floor only applies to tool-bearing requests)", decision.CandidateCount)
	}
}

// Scheduler integration: a provider advertising template_render_ok=false for
// the model must be skipped for tool requests even when its version meets the
// floor — and a fleet with no render-capable provider yields no selection
// rather than a guaranteed crash.
func TestReserveProviderExSkipsTemplateRenderBrokenForTools(t *testing.T) {
	reg := New(testLogger())
	model := "render-gate-model"
	broken := makeSchedulerProvider(t, reg, "render-broken", model, 200)
	healthy := makeSchedulerProvider(t, reg, "render-healthy", model, 50)
	setProviderVersion(broken, "0.6.5")
	setProviderVersion(healthy, "0.6.5")
	broken.mu.Lock()
	broken.Models[0].TemplateRenderOK = boolPtr(false)
	broken.mu.Unlock()
	healthy.mu.Lock()
	healthy.Models[0].TemplateRenderOK = boolPtr(true)
	healthy.mu.Unlock()

	toolReq := &PendingRequest{
		RequestID:          "r-render",
		Model:              model,
		RequestedMaxTokens: 128,
		Traits:             RequestTraits{HasTools: true},
	}
	selected, decision := reg.ReserveProviderEx(model, toolReq)
	if selected == nil || selected.ID != healthy.ID {
		t.Fatalf("tool request selected %v, want %q (render-broken excluded)", selected, healthy.ID)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("CandidateCount=%d, want 1", decision.CandidateCount)
	}
	healthy.RemovePending("r-render")

	// A plain (non-tool) request must ALSO avoid the render-broken provider: a
	// crashing chat template breaks every request shape for the pair, not just
	// tool-schema rendering. Only the healthy provider remains a candidate.
	plain := &PendingRequest{RequestID: "r-plain", Model: model, RequestedMaxTokens: 128}
	selected, decision = reg.ReserveProviderEx(model, plain)
	if selected == nil || selected.ID != healthy.ID {
		t.Fatalf("plain request selected %v, want %q (render-broken excluded for all shapes)", selected, healthy.ID)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("plain request CandidateCount=%d, want 1 (render-broken fences non-tool requests too)", decision.CandidateCount)
	}
}

// The model-list merge paths copy whole ModelInfo structs, so the
// template_render_ok pointer must survive both a models_update merge
// (MergeProviderModels) and a weight-hash refresh (UpdateModelWeightHashes,
// copy-on-write of the slice). If either ever switches to field-by-field
// copying and drops the verdict, the render gate silently stops excluding
// broken providers — this test pins the guarantee.
func TestModelMergePreservesTemplateRenderOK(t *testing.T) {
	reg := New(testLogger()) // nil catalog: no membership/hash gate in tests
	p := registerProviderWithModel(reg, "p1", "existing-model")

	renderVerdict := func(model string) *bool {
		p.mu.Lock()
		defer p.mu.Unlock()
		for _, m := range p.Models {
			if m.ID == model {
				return m.TemplateRenderOK
			}
		}
		t.Fatalf("model %q not advertised after merge", model)
		return nil
	}

	merged, _ := reg.MergeProviderModels("p1", []protocol.ModelInfo{
		{ID: "broken-build", TemplateRenderOK: boolPtr(false)},
		{ID: "existing-model", TemplateRenderOK: boolPtr(true)}, // in-place replace path
	})
	if len(merged) != 2 {
		t.Fatalf("merged=%v, want both builds", merged)
	}
	if v := renderVerdict("broken-build"); v == nil || *v {
		t.Fatalf("appended build lost TemplateRenderOK=false through merge, got %v", v)
	}
	if v := renderVerdict("existing-model"); v == nil || !*v {
		t.Fatalf("replaced build lost TemplateRenderOK=true through merge, got %v", v)
	}

	// Weight-hash refresh rewrites the Models slice copy-on-write; it must
	// only touch WeightHash and keep the render verdict intact.
	reg.UpdateModelWeightHashes("p1", map[string]string{"broken-build": "newhash"})
	if v := renderVerdict("broken-build"); v == nil || *v {
		t.Fatalf("TemplateRenderOK lost through UpdateModelWeightHashes, got %v", v)
	}
}

// Version-diverse retry is SOFT: prefer a different binary version when one is
// available, but never fail-closed when the whole fleet runs the avoided one.
func TestReserveProviderExVersionDiverseRetry(t *testing.T) {
	reg := New(testLogger())
	model := "diverse-retry-model"
	sameVer := makeSchedulerProvider(t, reg, "same-version", model, 200)
	otherVer := makeSchedulerProvider(t, reg, "other-version", model, 50)
	setProviderVersion(sameVer, "0.6.4")
	setProviderVersion(otherVer, "0.6.5")

	req := &PendingRequest{
		RequestID:          "r-avoid",
		Model:              model,
		RequestedMaxTokens: 128,
		Traits:             RequestTraits{AvoidVersion: "0.6.4"},
	}
	selected, _ := reg.ReserveProviderEx(model, req)
	if selected == nil || selected.ID != otherVer.ID {
		t.Fatalf("avoid-version retry selected %v, want %q (the diverse version)", selected, otherVer.ID)
	}
	otherVer.RemovePending("r-avoid")

	// Every candidate now runs the avoided version: diversity must fall back
	// to the full pool instead of failing the request.
	setProviderVersion(otherVer, "0.6.4")
	req2 := &PendingRequest{
		RequestID:          "r-avoid-all",
		Model:              model,
		RequestedMaxTokens: 128,
		Traits:             RequestTraits{AvoidVersion: "0.6.4"},
	}
	selected2, decision := reg.ReserveProviderEx(model, req2)
	if selected2 == nil {
		t.Fatal("diversity must never fail-closed: expected a provider even when all run the avoided version")
	}
	if decision.CandidateCount != 2 {
		t.Fatalf("CandidateCount=%d, want 2 (avoided-version providers stay in the candidate set)", decision.CandidateCount)
	}
	selected2.RemovePending("r-avoid-all")
	_ = sameVer
}

// HasToolCapableProviderForModel backs the consumer's tools fail-fast: it
// must report false when the model's WHOLE pool is trait-gated (below the
// tools floor, render-broken, offline, or untrusted) and flip true the moment
// one eligible provider serves the model.
func TestHasToolCapableProviderForModel(t *testing.T) {
	reg := New(testLogger())
	model := "tool-capable-model"

	// Only a below-floor provider serves the model → no tool capability.
	old := makeSchedulerProvider(t, reg, "old-binary", model, 200)
	setProviderVersion(old, "0.5.16")
	if reg.HasToolCapableProviderForModel(model) {
		t.Fatal("below-floor provider must not count as tool-capable")
	}

	// A provider past the floor but with an explicit broken template render
	// for this model still doesn't count.
	broken := makeSchedulerProvider(t, reg, "render-broken", model, 100)
	setProviderVersion(broken, "0.6.4")
	broken.mu.Lock()
	broken.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", TemplateRenderOK: boolPtr(false)}}
	broken.mu.Unlock()
	if reg.HasToolCapableProviderForModel(model) {
		t.Fatal("render-broken provider must not count as tool-capable")
	}

	// A past-floor provider serving a DIFFERENT model doesn't help this one.
	otherModel := makeSchedulerProvider(t, reg, "other-model", "some-other-model", 100)
	setProviderVersion(otherModel, "0.6.4")
	if reg.HasToolCapableProviderForModel(model) {
		t.Fatal("a tool-capable provider for another model must not count")
	}

	// One healthy past-floor provider for the model flips the answer.
	ok := makeSchedulerProvider(t, reg, "healthy", model, 50)
	setProviderVersion(ok, "0.6.4")
	if !reg.HasToolCapableProviderForModel(model) {
		t.Fatal("past-floor provider with no render verdict must count as tool-capable")
	}

	// Offline and untrusted providers don't count.
	ok.mu.Lock()
	ok.Status = StatusUntrusted
	ok.mu.Unlock()
	if reg.HasToolCapableProviderForModel(model) {
		t.Fatal("untrusted provider must not count as tool-capable")
	}
	ok.mu.Lock()
	ok.Status = StatusOffline
	ok.mu.Unlock()
	if reg.HasToolCapableProviderForModel(model) {
		t.Fatal("offline provider must not count as tool-capable")
	}
	ok.mu.Lock()
	ok.Status = StatusOnline
	ok.mu.Unlock()
	if !reg.HasToolCapableProviderForModel(model) {
		t.Fatal("restored online provider must count as tool-capable again")
	}
}
