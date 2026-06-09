package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func registerProviderWithModel(reg *Registry, id, modelID string) *Provider {
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: modelID, SizeBytes: 5_000_000_000, ModelType: "gemma", Quantization: "4bit"}}
	return reg.Register(id, nil, msg)
}

func makeProviderRoutable(p *Provider) {
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.mu.Unlock()
}

// Regression guard for the migration black-hole risk: a provider that merely
// advertises a build but can't actually route it (stale challenge) must be
// excluded from RoutableProviderIDsForBuild (the controller's ramp signal),
// even though ProvidersServingBuild (prefetch targeting) still sees it.
func TestRoutableProviderIDsExcludeUnroutable(t *testing.T) {
	reg := New(testLogger())
	const build = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

	good := registerProviderWithModel(reg, "good", build)
	makeProviderRoutable(good)

	stale := registerProviderWithModel(reg, "stale", build)
	makeProviderRoutable(stale)
	stale.mu.Lock()
	stale.LastChallengeVerified = time.Time{} // never challenged → unroutable
	stale.mu.Unlock()

	serving := reg.ProvidersServingBuild(build)
	if len(serving) != 2 {
		t.Fatalf("ProvidersServingBuild should see both advertisers, got %v", serving)
	}
	routable := reg.RoutableProviderIDsForBuild(build)
	if len(routable) != 1 || routable[0] != "good" {
		t.Fatalf("only the routable provider should count, got %v", routable)
	}
}

func TestResolveModelPassthroughForNonAlias(t *testing.T) {
	reg := New(testLogger())
	build, isAlias, ok := reg.ResolveModel("mlx-community/gemma-4-26b-a4b-it-fp8")
	if !ok || isAlias {
		t.Fatalf("non-alias should pass through: build=%q isAlias=%v ok=%v", build, isAlias, ok)
	}
	if build != "mlx-community/gemma-4-26b-a4b-it-fp8" {
		t.Fatalf("passthrough mismatch: %q", build)
	}
}

func TestResolveModelDrainedBuildNeverChosen(t *testing.T) {
	reg := New(testLogger())
	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	// fp8 fully drained (weight 0), qat at 100. Both have a provider.
	registerProviderWithModel(reg, "p-fp8", fp8)
	registerProviderWithModel(reg, "p-qat", qat)
	reg.SetModelAliases(map[string][]BuildRef{
		"gemma-4-26b": {{BuildID: fp8, Weight: 0}, {BuildID: qat, Weight: 100}},
	})

	for i := 0; i < 50; i++ {
		build, isAlias, ok := reg.ResolveModel("gemma-4-26b")
		if !ok || !isAlias {
			t.Fatalf("alias should resolve: isAlias=%v ok=%v", isAlias, ok)
		}
		if build != qat {
			t.Fatalf("drained build was chosen: got %q want %q", build, qat)
		}
	}
}

func TestResolveModelPrefersServableBuild(t *testing.T) {
	reg := New(testLogger())
	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	// Both builds have positive weight, but ONLY fp8 has a routable provider.
	// The ramping qat build has no provider yet, so traffic must still resolve
	// to fp8 (the zero-downtime fallback) rather than black-holing on qat.
	makeProviderRoutable(registerProviderWithModel(reg, "p-fp8", fp8))
	reg.SetModelAliases(map[string][]BuildRef{
		"gemma-4-26b": {{BuildID: fp8, Weight: 50}, {BuildID: qat, Weight: 50}},
	})

	for i := 0; i < 50; i++ {
		build, _, ok := reg.ResolveModel("gemma-4-26b")
		if !ok || build != fp8 {
			t.Fatalf("should fall back to servable fp8: got %q ok=%v", build, ok)
		}
	}
}

func TestResolveModelWeightedSplit(t *testing.T) {
	reg := New(testLogger())
	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	makeProviderRoutable(registerProviderWithModel(reg, "p-fp8", fp8))
	makeProviderRoutable(registerProviderWithModel(reg, "p-qat", qat))
	reg.SetModelAliases(map[string][]BuildRef{
		"gemma-4-26b": {{BuildID: fp8, Weight: 30}, {BuildID: qat, Weight: 70}},
	})

	counts := map[string]int{}
	const n = 4000
	for i := 0; i < n; i++ {
		build, _, ok := reg.ResolveModel("gemma-4-26b")
		if !ok {
			t.Fatal("resolve failed")
		}
		counts[build]++
	}
	// Expect roughly 30/70; allow generous slack for randomness.
	qatFrac := float64(counts[qat]) / float64(n)
	if qatFrac < 0.6 || qatFrac > 0.8 {
		t.Fatalf("weighted split off: qat fraction=%.2f (counts=%v)", qatFrac, counts)
	}
}

// A self-route request must resolve the alias to a build the OWNER's machine
// can serve, not to a build only a public (non-owned) provider has.
func TestResolveModelConstrainedSelfRoutePrefersOwnerBuild(t *testing.T) {
	reg := New(testLogger())
	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

	owner := registerProviderWithModel(reg, "owner", fp8)
	makeProviderRoutable(owner)
	owner.mu.Lock()
	owner.AccountID = "acct-1"
	owner.mu.Unlock()

	other := registerProviderWithModel(reg, "other", qat)
	makeProviderRoutable(other)
	other.mu.Lock()
	other.AccountID = "acct-2"
	other.mu.Unlock()

	reg.SetModelAliases(map[string][]BuildRef{
		"gemma-4-26b": {{BuildID: fp8, Weight: 50}, {BuildID: qat, Weight: 50}},
	})

	// Self-route to acct-1 (owns the fp8 machine): qat is only on the non-owned
	// machine, so resolution must pick fp8 every time.
	for i := 0; i < 50; i++ {
		b, isAlias, ok := reg.ResolveModelConstrained("gemma-4-26b", nil, "acct-1", true, false)
		if !ok || !isAlias || b != fp8 {
			t.Fatalf("self-route should resolve to owner's build fp8, got %q (isAlias=%v ok=%v)", b, isAlias, ok)
		}
	}
	// No constraints → delegates to ResolveModel (weighted across both builds).
	b, _, ok := reg.ResolveModelConstrained("gemma-4-26b", nil, "", false, false)
	if !ok || (b != fp8 && b != qat) {
		t.Fatalf("unconstrained resolve = %q ok=%v", b, ok)
	}
}

// A HARD-constrained request (serial pin or self-route-only) whose constraint no
// provider can satisfy must return model_unavailable — NOT fall back to a build
// that only a disallowed/non-owned provider serves (which would then fail at
// dispatch, or for self-route leak toward the fleet).
func TestResolveModelConstrainedNoFallbackWhenUnsatisfiable(t *testing.T) {
	reg := New(testLogger())
	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

	// Only a NON-owned provider (acct-2) serves a build; acct-1 owns nothing.
	other := registerProviderWithModel(reg, "other", qat)
	makeProviderRoutable(other)
	other.mu.Lock()
	other.AccountID = "acct-2"
	other.mu.Unlock()

	reg.SetModelAliases(map[string][]BuildRef{
		"gemma-4-26b": {{BuildID: fp8, Weight: 50}, {BuildID: qat, Weight: 50}},
	})

	// Self-route to acct-1: no owned provider serves any build → unavailable, and
	// must NOT fall back to qat (only the non-owned acct-2 serves it).
	if b, isAlias, ok := reg.ResolveModelConstrained("gemma-4-26b", nil, "acct-1", true, false); ok || b != "" || !isAlias {
		t.Fatalf("self-route with no owned provider: want (\"\", true, false), got (%q, %v, %v)", b, isAlias, ok)
	}
	// Serial pin to a serial no provider has → also unavailable (no fallback).
	if b, _, ok := reg.ResolveModelConstrained("gemma-4-26b", []string{"SERIAL-NONE"}, "", false, false); ok || b != "" {
		t.Fatalf("serial pin with no matching provider: want unavailable, got (%q, ok=%v)", b, ok)
	}
	// Sanity: acct-2 self-route (owns qat) still resolves.
	if b, _, ok := reg.ResolveModelConstrained("gemma-4-26b", nil, "acct-2", true, false); !ok || b != qat {
		t.Fatalf("acct-2 self-route should resolve to qat, got (%q, ok=%v)", b, ok)
	}
}

func TestPublicNameForBuild(t *testing.T) {
	reg := New(testLogger())
	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	reg.SetModelAliases(map[string][]BuildRef{
		"gemma-4-26b": {{BuildID: fp8, Weight: 50}, {BuildID: qat, Weight: 50}},
	})
	if got := reg.PublicNameForBuild(fp8); got != "gemma-4-26b" {
		t.Fatalf("fp8 should map to alias, got %q", got)
	}
	if got := reg.PublicNameForBuild(qat); got != "gemma-4-26b" {
		t.Fatalf("qat should map to alias, got %q", got)
	}
	// A build not part of any alias is returned unchanged (it is its own public name).
	if got := reg.PublicNameForBuild("mlx-community/other"); got != "mlx-community/other" {
		t.Fatalf("non-alias build should pass through, got %q", got)
	}
}

func TestProviderCanFitBuild(t *testing.T) {
	reg := New(testLogger())
	const small = "mlx-community/small"
	const big = "mlx-community/big"
	// testRegisterMessage advertises a 64 GB machine.
	registerProviderWithModel(reg, "p1", small)
	reg.SetModelCatalog([]CatalogEntry{
		{ID: small, MinRAMGB: 16},
		{ID: big, MinRAMGB: 200},
	})
	if !reg.ProviderCanFitBuild("p1", small) {
		t.Fatal("64GB machine should fit a 16GB-min build")
	}
	if reg.ProviderCanFitBuild("p1", big) {
		t.Fatal("64GB machine must NOT fit a 200GB-min build")
	}
	if reg.ProviderCanFitBuild("nope", small) {
		t.Fatal("unknown provider can't fit anything")
	}
}

func TestResolveModelNoUsableBuild(t *testing.T) {
	reg := New(testLogger())
	// Alias exists but every build is drained (weight 0) → not resolvable.
	reg.SetModelAliases(map[string][]BuildRef{
		"gemma-4-26b": {{BuildID: "b1", Weight: 0}},
	})
	_, isAlias, ok := reg.ResolveModel("gemma-4-26b")
	if !isAlias {
		t.Fatal("should be recognized as an alias")
	}
	if ok {
		t.Fatal("alias with only drained builds must not resolve")
	}
}

func TestMergeProviderModelsMakesProviderServeBuild(t *testing.T) {
	reg := New(testLogger())
	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	registerProviderWithModel(reg, "p1", fp8) // serves only fp8

	if got := reg.ProvidersServingBuild(qat); len(got) != 0 {
		t.Fatalf("qat should have no providers yet, got %v", got)
	}

	// Simulate the models_update a provider sends after a verified prefetch.
	merged := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: qat, ModelType: "gemma", WeightHash: "abc"}})
	if len(merged) != 1 || merged[0] != qat {
		t.Fatalf("merge should report qat, got %v", merged)
	}
	got := reg.ProvidersServingBuild(qat)
	if len(got) != 1 || got[0] != "p1" {
		t.Fatalf("p1 should now serve qat, got %v", got)
	}
	// The authoritative ModelType from the update is used.
	if mt := reg.ModelType(qat); mt != "gemma" {
		t.Fatalf("model type = %q, want gemma", mt)
	}
	// Re-merge updates in place (no duplicate entry).
	reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: qat, ModelType: "gemma", WeightHash: "abc"}})
	if got := reg.ProvidersServingBuild(qat); len(got) != 1 {
		t.Fatalf("re-merge should not duplicate, got %v", got)
	}
	// Unknown provider is a safe no-op.
	if m := reg.MergeProviderModels("nope", []protocol.ModelInfo{{ID: qat}}); m != nil {
		t.Fatalf("unknown provider should be a no-op, got %v", m)
	}
}

// A models_update whose weight hash doesn't match the catalog's expected hash is
// rejected — a bad/buggy prefetch must never become routable.
func TestMergeProviderModelsRejectsHashMismatch(t *testing.T) {
	reg := New(testLogger())
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	registerProviderWithModel(reg, "p1", "mlx-community/base")
	reg.SetModelCatalog([]CatalogEntry{{ID: qat, WeightHash: "EXPECTED"}})

	if m := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: qat, WeightHash: "WRONG"}}); len(m) != 0 {
		t.Fatalf("hash mismatch must be rejected, got %v", m)
	}
	if got := reg.ProvidersServingBuild(qat); len(got) != 0 {
		t.Fatalf("rejected build must not be advertised, got %v", got)
	}
	if m := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: qat, WeightHash: "EXPECTED"}}); len(m) != 1 {
		t.Fatalf("matching hash must merge, got %v", m)
	}
}

func TestSetModelAliasesClearAndCopy(t *testing.T) {
	reg := New(testLogger())
	builds := []BuildRef{{BuildID: "b1", Weight: 100}}
	reg.SetModelAliases(map[string][]BuildRef{"a": builds})
	// Mutating the caller's slice must not affect the stored copy.
	builds[0].Weight = 0
	if got := reg.AliasBuilds("a"); len(got) != 1 || got[0].Weight != 100 {
		t.Fatalf("alias builds not deep-copied: %+v", got)
	}
	if !reg.IsAlias("a") {
		t.Fatal("IsAlias should report true")
	}
	reg.SetModelAliases(nil)
	if reg.IsAlias("a") {
		t.Fatal("aliases should be cleared")
	}
}
