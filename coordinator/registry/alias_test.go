package registry

import (
	"strconv"
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

const (
	aliasFP8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	aliasQAT = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
)

// Regression guard for the hard-swap drop / routability gate: a provider that
// merely advertises a build but can't actually route it (stale challenge) must be
// excluded from RoutableProviderIDsForBuild.
func TestRoutableProviderIDsExcludeUnroutable(t *testing.T) {
	reg := New(testLogger())
	const build = aliasQAT

	good := registerProviderWithModel(reg, "good", build)
	makeProviderRoutable(good)

	stale := registerProviderWithModel(reg, "stale", build)
	makeProviderRoutable(stale)
	stale.mu.Lock()
	stale.LastChallengeVerified = time.Time{} // never challenged → unroutable
	stale.mu.Unlock()

	crashed := registerProviderWithModel(reg, "crashed", build)
	makeProviderRoutable(crashed)
	crashed.mu.Lock()
	crashed.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots:         []protocol.BackendSlotCapacity{{Model: build, State: "crashed"}},
	}
	crashed.mu.Unlock()

	routable := reg.RoutableProviderIDsForBuild(build)
	if len(routable) != 1 || routable[0] != "good" {
		t.Fatalf("only the routable provider should count, got %v", routable)
	}
}

func TestResolveModelPassthroughForNonAlias(t *testing.T) {
	reg := New(testLogger())
	build, isAlias, ok := reg.ResolveModel(aliasFP8)
	if !ok || isAlias {
		t.Fatalf("non-alias should pass through: build=%q isAlias=%v ok=%v", build, isAlias, ok)
	}
	if build != aliasFP8 {
		t.Fatalf("passthrough mismatch: %q", build)
	}
}

// Desired build is routable → resolution always picks it.
func TestResolveModelPrefersDesired(t *testing.T) {
	reg := New(testLogger())
	makeProviderRoutable(registerProviderWithModel(reg, "p-desired", aliasQAT))
	makeProviderRoutable(registerProviderWithModel(reg, "p-prev", aliasFP8))
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})

	for i := 0; i < 50; i++ {
		build, isAlias, ok := reg.ResolveModel("gemma-4-26b")
		if !ok || !isAlias || build != aliasQAT {
			t.Fatalf("should resolve to desired qat: got %q isAlias=%v ok=%v", build, isAlias, ok)
		}
	}
}

// Desired build not routable yet but previous is → fall back to previous (the
// zero-downtime guarantee during a staggered rollout).
func TestResolveModelAcceptsPreviousWhenDesiredUnroutable(t *testing.T) {
	reg := New(testLogger())
	// Only the previous build has a routable provider; desired has none yet.
	makeProviderRoutable(registerProviderWithModel(reg, "p-prev", aliasFP8))
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})

	for i := 0; i < 50; i++ {
		build, _, ok := reg.ResolveModel("gemma-4-26b")
		if !ok || build != aliasFP8 {
			t.Fatalf("should fall back to routable previous fp8: got %q ok=%v", build, ok)
		}
	}
}

// Neither build is routable → resolve to the desired build so the request queues
// against a real build instead of black-holing or failing outright.
func TestResolveModelQueuesAgainstDesiredWhenNoneRoutable(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})
	build, isAlias, ok := reg.ResolveModel("gemma-4-26b")
	if !isAlias || !ok {
		t.Fatalf("alias should resolve (queue) even with no provider: isAlias=%v ok=%v", isAlias, ok)
	}
	if build != aliasQAT {
		t.Fatalf("should queue against desired build, got %q", build)
	}
}

// An alias with an empty desired build is unresolvable.
func TestResolveModelEmptyDesiredUnavailable(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: "", Previous: aliasFP8},
	})
	_, isAlias, ok := reg.ResolveModel("gemma-4-26b")
	if !isAlias {
		t.Fatal("should be recognized as an alias")
	}
	if ok {
		t.Fatal("alias with empty desired build must not resolve")
	}
}

// A self-route request must resolve the alias to a build the OWNER's machine can
// serve, preferring desired, then previous.
func TestResolveModelConstrainedSelfRoutePrefersOwnerBuild(t *testing.T) {
	reg := New(testLogger())

	owner := registerProviderWithModel(reg, "owner", aliasFP8)
	makeProviderRoutable(owner)
	owner.mu.Lock()
	owner.AccountID = "acct-1"
	owner.mu.Unlock()

	other := registerProviderWithModel(reg, "other", aliasQAT)
	makeProviderRoutable(other)
	other.mu.Lock()
	other.AccountID = "acct-2"
	other.mu.Unlock()

	// Desired = qat (only on the non-owned machine), previous = fp8 (on owner).
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})

	// Self-route to acct-1: desired qat is not on an owned machine, so it must
	// fall back to the owner's previous build fp8 every time.
	for i := 0; i < 50; i++ {
		b, isAlias, ok := reg.ResolveModelConstrained("gemma-4-26b", nil, "acct-1", true, false)
		if !ok || !isAlias || b != aliasFP8 {
			t.Fatalf("self-route should resolve to owner's build fp8, got %q (isAlias=%v ok=%v)", b, isAlias, ok)
		}
	}
	// No constraints → delegates to ResolveModel (desired qat is routable).
	b, _, ok := reg.ResolveModelConstrained("gemma-4-26b", nil, "", false, false)
	if !ok || b != aliasQAT {
		t.Fatalf("unconstrained resolve = %q ok=%v, want desired qat", b, ok)
	}
}

func TestResolveModelConstrainedPreferOwnerUsesOwnedBuildBeforePublicDesired(t *testing.T) {
	reg := New(testLogger())
	makeProviderRoutable(registerProviderWithModel(reg, "public-qat", aliasQAT))

	ownedPrev := registerProviderWithModel(reg, "owned-fp8", aliasFP8)
	ownedPrev.mu.Lock()
	ownedPrev.AccountID = "acct-1"
	ownedPrev.mu.Unlock()
	makeProviderRoutable(ownedPrev)

	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})

	b, isAlias, ok := reg.ResolveModelConstrained("gemma-4-26b", nil, "acct-1", false, true)
	if !ok || !isAlias || b != aliasFP8 {
		t.Fatalf("prefer-owner should choose owned previous before public desired, got %q isAlias=%v ok=%v", b, isAlias, ok)
	}
}

// A HARD-constrained request (serial pin or self-route-only) whose constraint no
// provider can satisfy must return model_unavailable — NOT fall back to a build
// that only a disallowed/non-owned provider serves.
func TestResolveModelConstrainedNoFallbackWhenUnsatisfiable(t *testing.T) {
	reg := New(testLogger())

	// Only a NON-owned provider (acct-2) serves a build; acct-1 owns nothing.
	other := registerProviderWithModel(reg, "other", aliasQAT)
	makeProviderRoutable(other)
	other.mu.Lock()
	other.AccountID = "acct-2"
	other.mu.Unlock()

	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})

	// Self-route to acct-1: no owned provider serves either build → unavailable.
	if b, isAlias, ok := reg.ResolveModelConstrained("gemma-4-26b", nil, "acct-1", true, false); ok || b != "" || !isAlias {
		t.Fatalf("self-route with no owned provider: want (\"\", true, false), got (%q, %v, %v)", b, isAlias, ok)
	}
	// Serial pin to a serial no provider has → also unavailable.
	if b, _, ok := reg.ResolveModelConstrained("gemma-4-26b", []string{"SERIAL-NONE"}, "", false, false); ok || b != "" {
		t.Fatalf("serial pin with no matching provider: want unavailable, got (%q, ok=%v)", b, ok)
	}
	// Sanity: acct-2 self-route (owns qat = desired) still resolves.
	if b, _, ok := reg.ResolveModelConstrained("gemma-4-26b", nil, "acct-2", true, false); !ok || b != aliasQAT {
		t.Fatalf("acct-2 self-route should resolve to qat, got (%q, ok=%v)", b, ok)
	}
}

func TestPublicNameForBuild(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})
	if got := reg.PublicNameForBuild(aliasFP8); got != "gemma-4-26b" {
		t.Fatalf("previous build should map to alias, got %q", got)
	}
	if got := reg.PublicNameForBuild(aliasQAT); got != "gemma-4-26b" {
		t.Fatalf("desired build should map to alias, got %q", got)
	}
	// A build not part of any alias is returned unchanged.
	if got := reg.PublicNameForBuild("mlx-community/other"); got != "mlx-community/other" {
		t.Fatalf("non-alias build should pass through, got %q", got)
	}
	// Empty input is returned unchanged (no panic).
	if got := reg.PublicNameForBuild(""); got != "" {
		t.Fatalf("empty build id should pass through, got %q", got)
	}
}

func TestMergeProviderModelsMakesProviderServeBuild(t *testing.T) {
	reg := New(testLogger())
	makeProviderRoutable(registerProviderWithModel(reg, "p1", aliasFP8)) // serves only fp8

	if got := reg.RoutableProviderIDsForBuild(aliasQAT); len(got) != 0 {
		t.Fatalf("qat should have no providers yet, got %v", got)
	}

	// Simulate the authoritative models_update a provider sends after converging.
	merged, dropped := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: aliasQAT, ModelType: "gemma", WeightHash: "abc"}})
	if len(merged) != 1 || merged[0] != aliasQAT {
		t.Fatalf("merge should report qat, got %v", merged)
	}
	if len(dropped) != 0 {
		t.Fatalf("merge without alias drop should not report dropped builds, got %v", dropped)
	}
	got := reg.RoutableProviderIDsForBuild(aliasQAT)
	if len(got) != 1 || got[0] != "p1" {
		t.Fatalf("p1 should now serve qat, got %v", got)
	}
	// The authoritative ModelType from the update is used.
	if mt := reg.ModelType(aliasQAT); mt != "gemma" {
		t.Fatalf("model type = %q, want gemma", mt)
	}
	// Re-merge updates in place (no duplicate entry).
	reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: aliasQAT, ModelType: "gemma", WeightHash: "abc"}})
	if got := reg.RoutableProviderIDsForBuild(aliasQAT); len(got) != 1 {
		t.Fatalf("re-merge should not duplicate, got %v", got)
	}
	// Unknown provider is a safe no-op.
	if m, d := reg.MergeProviderModels("nope", []protocol.ModelInfo{{ID: aliasQAT}}); m != nil || d != nil {
		t.Fatalf("unknown provider should be a no-op, got merged=%v dropped=%v", m, d)
	}
}

// The hard-swap drop: a provider serving the previous build that re-advertises
// ONLY the desired build (an authoritative models_update for the alias) must lose
// routability for the previous build — the retired quant is dropped.
func TestMergeProviderModelsHardSwapDropsPreviousBuild(t *testing.T) {
	reg := New(testLogger())
	// p1 serves the previous build (fp8) and is the alias's desired→previous pair.
	makeProviderRoutable(registerProviderWithModel(reg, "p1", aliasFP8))
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})
	if got := reg.RoutableProviderIDsForBuild(aliasFP8); len(got) != 1 {
		t.Fatalf("p1 should serve fp8 initially, got %v", got)
	}

	// p1 converges: it now advertises ONLY the desired build qat.
	_, dropped := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: aliasQAT, ModelType: "gemma"}})
	if len(dropped) != 1 || dropped[0] != aliasFP8 {
		t.Fatalf("hard-swap drop should report fp8, got %v", dropped)
	}

	if got := reg.RoutableProviderIDsForBuild(aliasQAT); len(got) != 1 || got[0] != "p1" {
		t.Fatalf("p1 should serve qat after swap, got %v", got)
	}
	if got := reg.RoutableProviderIDsForBuild(aliasFP8); len(got) != 0 {
		t.Fatalf("fp8 must be dropped on p1 after hard-swap, got %v", got)
	}
}

// A models_update whose weight hash doesn't match the catalog's expected hash is
// rejected — a bad/buggy swap must never become routable.
func TestMergeProviderModelsRejectsHashMismatch(t *testing.T) {
	reg := New(testLogger())
	makeProviderRoutable(registerProviderWithModel(reg, "p1", "mlx-community/base"))
	reg.SetModelCatalog([]CatalogEntry{{ID: aliasQAT, WeightHash: "EXPECTED"}})

	if m, _ := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: aliasQAT, WeightHash: "WRONG"}}); len(m) != 0 {
		t.Fatalf("hash mismatch must be rejected, got %v", m)
	}
	// A MISSING hash is rejected too when the catalog pins one (not merged as valid).
	if m, _ := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: aliasQAT}}); len(m) != 0 {
		t.Fatalf("missing hash must be rejected when catalog pins one, got %v", m)
	}
	if got := reg.RoutableProviderIDsForBuild(aliasQAT); len(got) != 0 {
		t.Fatalf("rejected build must not be advertised, got %v", got)
	}
	if m, _ := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: aliasQAT, WeightHash: "EXPECTED"}}); len(m) != 1 {
		t.Fatalf("matching hash must merge, got %v", m)
	}
}

// Regression: a models_update whose DESIRED build fails the catalog weight-hash
// check must NOT drop the still-valid PREVIOUS build. Deriving the hard-swap
// drop from the raw message (before validation) would strand the provider on
// neither build — the exact rollout failure the hash check exists to prevent.
func TestMergeProviderModelsRejectedDesiredDoesNotDropPrevious(t *testing.T) {
	reg := New(testLogger())
	// p1 serves the previous build (fp8); the catalog pins qat's expected hash.
	makeProviderRoutable(registerProviderWithModel(reg, "p1", aliasFP8))
	reg.SetModelCatalog([]CatalogEntry{
		{ID: aliasFP8},
		{ID: aliasQAT, WeightHash: "EXPECTED"},
	})
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})
	if got := reg.RoutableProviderIDsForBuild(aliasFP8); len(got) != 1 {
		t.Fatalf("p1 should serve fp8 initially, got %v", got)
	}

	// p1 sends an authoritative update advertising ONLY the desired build, but
	// with a BAD weight hash → the desired build is rejected (not merged).
	merged, dropped := reg.MergeProviderModels("p1", []protocol.ModelInfo{
		{ID: aliasQAT, ModelType: "gemma", WeightHash: "WRONG"},
	})
	if len(merged) != 0 {
		t.Fatalf("hash-mismatched desired must be rejected, got merged %v", merged)
	}
	if len(dropped) != 0 {
		t.Fatalf("hash-mismatched desired must not drop previous, got dropped %v", dropped)
	}
	// Desired must NOT be routable (rejected)...
	if got := reg.RoutableProviderIDsForBuild(aliasQAT); len(got) != 0 {
		t.Fatalf("rejected desired must not be routable, got %v", got)
	}
	// ...and the previous build must STILL be routable (not collateral-dropped).
	if got := reg.RoutableProviderIDsForBuild(aliasFP8); len(got) != 1 || got[0] != "p1" {
		t.Fatalf("previous build must survive a rejected desired update, got %v", got)
	}
}

// Regression (re-review): a models_update that OMITS weight_hash for a build
// whose catalog entry pins an expected hash must be rejected — not merged as if
// validated — and must NOT drop the previous sibling. A missing hash is as
// untrusted as a wrong one; merging it would cut the provider over to an
// unverified build while retiring the last known-good previous build.
func TestMergeProviderModelsRejectsMissingHashAndKeepsPrevious(t *testing.T) {
	reg := New(testLogger())
	makeProviderRoutable(registerProviderWithModel(reg, "p1", aliasFP8))
	reg.SetModelCatalog([]CatalogEntry{
		{ID: aliasFP8},
		{ID: aliasQAT, WeightHash: "EXPECTED"},
	})
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})
	if got := reg.RoutableProviderIDsForBuild(aliasFP8); len(got) != 1 {
		t.Fatalf("p1 should serve fp8 initially, got %v", got)
	}

	// Desired build update with NO weight hash (empty), catalog expects one.
	merged, dropped := reg.MergeProviderModels("p1", []protocol.ModelInfo{
		{ID: aliasQAT, ModelType: "gemma"}, // WeightHash == ""
	})
	if len(merged) != 0 {
		t.Fatalf("missing-hash desired must be rejected, got merged %v", merged)
	}
	if len(dropped) != 0 {
		t.Fatalf("missing-hash desired must not drop previous, got dropped %v", dropped)
	}
	if got := reg.RoutableProviderIDsForBuild(aliasQAT); len(got) != 0 {
		t.Fatalf("hashless desired must not be routable, got %v", got)
	}
	if got := reg.RoutableProviderIDsForBuild(aliasFP8); len(got) != 1 || got[0] != "p1" {
		t.Fatalf("previous build must survive a hashless desired update, got %v", got)
	}

	// A build with NO catalog-pinned hash is still accepted hashless (the gate
	// only bites when the catalog pins an expected hash).
	reg.SetModelCatalog([]CatalogEntry{{ID: aliasFP8}, {ID: aliasQAT}}) // no expected hashes
	if m, _ := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: aliasQAT, ModelType: "gemma"}}); len(m) != 1 {
		t.Fatalf("hashless build with no pinned catalog hash must merge, got %v", m)
	}
}

func TestMergeProviderModelsDoesNotDropSiblingForUnrelatedSharedAlias(t *testing.T) {
	reg := New(testLogger())
	const (
		oldA   = "alias-a-old"
		shared = "shared-build"
		other  = "alias-b-other"
	)
	p := registerProviderWithModel(reg, "p1", oldA)
	p.mu.Lock()
	p.Models = append(p.Models,
		protocol.ModelInfo{ID: shared, ModelType: "gemma"},
		protocol.ModelInfo{ID: other, ModelType: "gemma"},
	)
	p.mu.Unlock()
	makeProviderRoutable(p)
	reg.SetModelCatalog([]CatalogEntry{{ID: oldA}, {ID: shared}, {ID: other}})
	reg.SetModelAliases(map[string]AliasTarget{
		"alias-a": {Desired: shared, Previous: oldA},
		"alias-b": {Desired: other, Previous: shared},
	})

	_, dropped := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: shared, ModelType: "gemma"}})
	if len(dropped) != 1 || dropped[0] != oldA {
		t.Fatalf("shared desired update should drop only alias-a previous, got %v", dropped)
	}
	if got := reg.RoutableProviderIDsForBuild(other); len(got) != 1 || got[0] != "p1" {
		t.Fatalf("unrelated alias-b desired build must remain routable, got %v", got)
	}
}

func TestSetModelAliasesClearAndIsAlias(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelAliases(map[string]AliasTarget{"a": {Desired: "b1"}})
	if !reg.IsAlias("a") {
		t.Fatal("IsAlias should report true")
	}
	if b, isAlias, ok := reg.ResolveModel("a"); !isAlias || !ok || b != "b1" {
		t.Fatalf("resolve = %q isAlias=%v ok=%v", b, isAlias, ok)
	}
	reg.SetModelAliases(nil)
	if reg.IsAlias("a") {
		t.Fatal("aliases should be cleared")
	}
}

// DesiredModelsForProvider emits an entry only for aliases whose desired OR
// previous build the provider already advertises.
func TestDesiredModelsForProviderConservative(t *testing.T) {
	reg := New(testLogger())
	registerProviderWithModel(reg, "p-fp8", aliasFP8) // advertises the previous build
	registerProviderWithModel(reg, "p-none", "mlx-community/unrelated")
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8},
	})

	// p-fp8 advertises the previous build → it is told the desired build.
	got := reg.DesiredModelsForProvider("p-fp8")
	if len(got) != 1 || got[0].ModelName != "gemma-4-26b" || got[0].DesiredBuild != aliasQAT || got[0].PreviousBuild != aliasFP8 {
		t.Fatalf("p-fp8 should be told the desired build, got %+v", got)
	}
	// p-none advertises nothing in the alias → not told.
	if got := reg.DesiredModelsForProvider("p-none"); len(got) != 0 {
		t.Fatalf("p-none should not be offered the alias, got %+v", got)
	}
	// Unknown provider → nil.
	if got := reg.DesiredModelsForProvider("nope"); got != nil {
		t.Fatalf("unknown provider should be nil, got %+v", got)
	}
}

// A provider that was offline through a retirement (still advertising only a
// RETIRED member of the alias) is still recognized as part of the alias's fleet
// at registration and told to converge — without this it would be permanently
// stranded serving zero alias traffic (runbook Step 7 reconnect recovery).
func TestDesiredModelsForProviderMatchesRetiredLineage(t *testing.T) {
	reg := New(testLogger())
	registerProviderWithModel(reg, "p-retired", aliasFP8) // advertises only the retired build
	registerProviderWithModel(reg, "p-none", "mlx-community/unrelated")
	// Migration finished: previous cleared, fp8 moved to the retired lineage.
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT, Retired: []string{aliasFP8}},
	})

	got := reg.DesiredModelsForProvider("p-retired")
	if len(got) != 1 || got[0].ModelName != "gemma-4-26b" || got[0].DesiredBuild != aliasQAT {
		t.Fatalf("returning provider on a retired build should be told the desired build, got %+v", got)
	}
	// PreviousBuild in the entry reflects the alias (empty here) — the retired
	// build is NOT re-blessed as acceptable.
	if got[0].PreviousBuild != "" {
		t.Fatalf("retired build must not be re-advertised as previous, got %+v", got[0])
	}
	if got := reg.DesiredModelsForProvider("p-none"); len(got) != 0 {
		t.Fatalf("unrelated provider should not be offered the alias, got %+v", got)
	}
}

// A models_update carrying a build id the catalog has never heard of is
// rejected outright when a catalog exists: it could never be routed, and
// merging it would let a provider grow its own p.Models without bound via
// fabricated ids. A nil catalog (dev/test setups) keeps the permissive
// behavior, mirroring modelAllowedByCatalogLocked.
func TestMergeProviderModelsRejectsNonCatalogBuild(t *testing.T) {
	reg := New(testLogger())
	makeProviderRoutable(registerProviderWithModel(reg, "p1", aliasFP8))
	reg.SetModelCatalog([]CatalogEntry{{ID: aliasFP8}, {ID: aliasQAT}})

	merged, dropped := reg.MergeProviderModels("p1", []protocol.ModelInfo{
		{ID: "mlx-community/fabricated-build", ModelType: "gemma"},
		{ID: aliasQAT, ModelType: "gemma"},
	})
	if len(merged) != 1 || merged[0] != aliasQAT {
		t.Fatalf("only the catalog build should merge, got %v", merged)
	}
	if len(dropped) != 0 {
		t.Fatalf("no drops expected, got %v", dropped)
	}

	// Repeated fabricated-id updates must not grow p.Models.
	for i := 0; i < 5; i++ {
		reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: "fake/build-" + strconv.Itoa(i)}})
	}
	p := reg.GetProvider("p1")
	p.mu.Lock()
	n := len(p.Models)
	p.mu.Unlock()
	if n != 2 { // fp8 (registered) + qat (merged)
		t.Fatalf("p.Models should stay at 2 entries, got %d", n)
	}

	// Nil catalog (dev mode): non-catalog ids still merge.
	devReg := New(testLogger())
	makeProviderRoutable(registerProviderWithModel(devReg, "p1", aliasFP8))
	if m, _ := devReg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: "anything/goes"}}); len(m) != 1 {
		t.Fatalf("nil catalog should keep permissive merge, got %v", m)
	}
}
