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
	// Both builds have positive weight, but ONLY fp8 has a registered provider.
	// The ramping qat build has no provider yet, so traffic must still resolve
	// to fp8 (the zero-downtime fallback) rather than black-holing on qat.
	registerProviderWithModel(reg, "p-fp8", fp8)
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
	registerProviderWithModel(reg, "p-fp8", fp8)
	registerProviderWithModel(reg, "p-qat", qat)
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

func TestMarkBuildPrefetchedMakesProviderServeBuild(t *testing.T) {
	reg := New(testLogger())
	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	registerProviderWithModel(reg, "p1", fp8) // serves only fp8

	if got := reg.ProvidersServingBuild(qat); len(got) != 0 {
		t.Fatalf("qat should have no providers yet, got %v", got)
	}

	// Simulate a verified prefetch of qat on p1.
	if !reg.MarkBuildPrefetched("p1", qat) {
		t.Fatal("MarkBuildPrefetched should report a newly added build")
	}
	// Idempotent: second call is a no-op.
	if reg.MarkBuildPrefetched("p1", qat) {
		t.Fatal("MarkBuildPrefetched should be idempotent")
	}

	got := reg.ProvidersServingBuild(qat)
	if len(got) != 1 || got[0] != "p1" {
		t.Fatalf("p1 should now serve qat, got %v", got)
	}
	// ModelType is inherited from the existing fp8 entry (same logical model).
	if mt := reg.ModelType(qat); mt != "gemma" {
		t.Fatalf("inherited model type = %q, want gemma", mt)
	}
	// Unknown provider is a safe no-op.
	if reg.MarkBuildPrefetched("nope", qat) {
		t.Fatal("unknown provider should be a no-op")
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
