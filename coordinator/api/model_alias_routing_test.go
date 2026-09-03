package api

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// aliasModelEntries returns the alias entry and the set of builds it covers,
// hiding retired lineage while aggregating active capacity from desired + previous.
func TestAliasModelEntriesHidesBuilds(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B (fp8)")
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B (qat-4bit)")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8, RetiredBuilds: []string{"gemma-4-26b-retired"},
	}); err != nil {
		t.Fatal(err)
	}

	_, registryByID, err := srv.activeCatalogLookups()
	if err != nil {
		t.Fatal(err)
	}
	catalogByID := map[string]store.SupportedModel{
		aliasFP8:              {ID: aliasFP8, Active: true, ModelType: "text"},
		aliasQAT:              {ID: aliasQAT, Active: true, ModelType: "text"},
		"gemma-4-26b-retired": {ID: "gemma-4-26b-retired", Active: true, ModelType: "text"},
	}
	capByModel := map[string]*registry.ModelCapacity{
		aliasQAT:              {ModelID: aliasQAT, RoutableProviders: 2, WarmProviders: 1, CanAccept: true},
		aliasFP8:              {ModelID: aliasFP8, RoutableProviders: 1, WarmProviders: 0, CanAccept: false},
		"gemma-4-26b-retired": {ModelID: "gemma-4-26b-retired", RoutableProviders: 10, WarmProviders: 10, CanAccept: true},
	}

	entries, hidden := srv.aliasModelEntries(capByModel, catalogByID, registryByID)
	if len(entries) != 1 || entries[0].ID != "gemma-4-26b" {
		t.Fatalf("expected one alias entry, got %+v", entries)
	}
	if entries[0].HuggingFaceID != aliasQAT {
		t.Fatalf("alias hugging_face_id = %q, want primary build %q", entries[0].HuggingFaceID, aliasQAT)
	}
	// Capacity aggregates across desired + previous only (2 + 1 = 3 routable);
	// retired builds are hide-only and must not count as active alias capacity.
	if entries[0].Metadata.RoutableProviders != 3 || entries[0].Metadata.WarmProviders != 1 || !entries[0].Metadata.CanAccept {
		t.Fatalf("alias capacity not aggregated: %+v", entries[0].Metadata)
	}
	if _, ok := hidden[aliasFP8]; !ok {
		t.Fatalf("fp8 (previous) build should be hidden: %v", hidden)
	}
	if _, ok := hidden[aliasQAT]; !ok {
		t.Fatalf("qat (desired) build should be hidden: %v", hidden)
	}
	if _, ok := hidden["gemma-4-26b-retired"]; !ok {
		t.Fatalf("retired build should be hidden without counting capacity: %v", hidden)
	}
}

// An alias whose desired build isn't in the catalog yet falls back to the
// previous build for its primary metadata; an alias with no in-catalog build is
// not advertised.
func TestAliasModelEntriesDesiredNotInCatalog(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "fp8 only")
	// Only fp8 (previous) is in the catalog; qat (desired) isn't registered yet.
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	// An alias whose desired build is empty / has no in-catalog build is skipped.
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "ghost", DisplayName: "Ghost", Active: true,
		DesiredBuild: "mlx-community/not-registered",
	}); err != nil {
		t.Fatal(err)
	}

	_, registryByID, err := srv.activeCatalogLookups()
	if err != nil {
		t.Fatal(err)
	}
	catalogByID := map[string]store.SupportedModel{aliasFP8: {ID: aliasFP8, Active: true, ModelType: "text"}}
	entries, hidden := srv.aliasModelEntries(map[string]*registry.ModelCapacity{}, catalogByID, registryByID)
	if len(entries) != 1 || entries[0].ID != "gemma-4-26b" {
		t.Fatalf("only the alias with an in-catalog build should list, got %+v", entries)
	}
	if _, ok := hidden[aliasFP8]; !ok {
		t.Fatalf("previous build should still be hidden, got %v", hidden)
	}
	if _, ok := hidden["mlx-community/not-registered"]; ok {
		t.Fatalf("a skipped alias must not hide its build, got %v", hidden)
	}
}

// Routing through aliasModelEntries / ResolveModel: when only the previous build
// has routable providers the alias resolves to previous; once desired is routable
// it resolves to desired.
func TestAliasRoutingDesiredAndPrevious(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	// Only the previous build is routable → resolve to previous.
	registerBuildsProvider(srv, "p-prev", aliasFP8)
	for i := 0; i < 50; i++ {
		if b, _, ok := reg.ResolveModel("gemma-4-26b"); !ok || b != aliasFP8 {
			t.Fatalf("should route to previous fp8, got %q ok=%v", b, ok)
		}
	}

	// Now the desired build becomes routable → resolve to desired.
	registerBuildsProvider(srv, "p-desired", aliasQAT)
	for i := 0; i < 50; i++ {
		if b, _, ok := reg.ResolveModel("gemma-4-26b"); !ok || b != aliasQAT {
			t.Fatalf("should route to desired qat once routable, got %q ok=%v", b, ok)
		}
	}
}

func TestAliasCapacityFallbackUsesPreviousWhenDesiredFull(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	registerBuildsProvider(srv, "p-prev", aliasFP8)
	registerBuildsProvider(srv, "p-desired", aliasQAT)
	p := reg.GetProvider("p-desired")
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1_000
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1_000
	p.Mu().Unlock()

	if candidates, rejections, _ := reg.QuickCapacityCheck(aliasQAT, 10, 128, registry.RequestTraits{}); candidates != 0 || rejections != 1 {
		t.Fatalf("desired capacity = candidates %d rejections %d, want 0/1", candidates, rejections)
	}
	if candidates, rejections, _ := reg.QuickCapacityCheck(aliasFP8, 10, 128, registry.RequestTraits{}); candidates != 1 || rejections != 0 {
		t.Fatalf("previous capacity = candidates %d rejections %d, want 1/0", candidates, rejections)
	}

	parsed := map[string]any{
		"model":    aliasQAT,
		"messages": []any{map[string]any{"role": "user", "content": "hi"}},
	}
	fallback, _, _, _, _, _, switched := srv.maybeFallbackAlias(parsed, aliasFallbackCapacity, "gemma-4-26b", aliasQAT, 10, 128, 0, registry.RequestTraits{}, false, nil)
	if !switched || fallback != aliasFP8 {
		t.Fatalf("fallback = %q switched=%v, want previous %q", fallback, switched, aliasFP8)
	}
	if parsed["model"] != aliasFP8 {
		t.Fatalf("parsed model = %q, want fallback build", parsed["model"])
	}
}
