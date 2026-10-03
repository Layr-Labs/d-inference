package catalog

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

const (
	aliasFP8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	aliasQAT = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
)

func seedActiveModel(t *testing.T, st store.Store, modelID, displayName string) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: displayName, Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 8192, MinRAMGB: 24,
		Capabilities: []string{"chat"}, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}
}

func TestAliasModelEntriesHidesBuilds(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{})
	srv := New(registry.New(logger), st, nil, readcache.New(), logger, Hooks{})

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
	st := memory.NewMemory(store.Config{})
	srv := New(registry.New(logger), st, nil, readcache.New(), logger, Hooks{})

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
func TestRetiredBuildsAfterUpsert(t *testing.T) {
	// No prior alias → no lineage.
	if got := retiredBuildsAfterUpsert(nil, "b2", ""); got != nil {
		t.Fatalf("no prior should yield nil, got %v", got)
	}
	// Rotation: desired b1→b2 (previous b1) retires nothing (b1 still a member);
	// then b2→b3 with previous cleared retires both b2 and b1.
	step1 := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "b1"}, "b2", "b1")
	if len(step1) != 0 {
		t.Fatalf("members must not be retired, got %v", step1)
	}
	step2 := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "b2", PreviousBuild: "b1"}, "b3", "")
	if len(step2) != 2 || step2[0] != "b2" || step2[1] != "b1" {
		t.Fatalf("rotated-out members should be retired, got %v", step2)
	}
	// Re-promotion: b1 comes back as desired → leaves the lineage.
	step3 := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "b3", RetiredBuilds: []string{"b2", "b1"}}, "b1", "")
	if len(step3) != 2 || step3[0] != "b2" || step3[1] != "b3" {
		t.Fatalf("re-promoted build must leave lineage and old desired must join, got %v", step3)
	}
	// Bound: the oldest entries are dropped first.
	var many []string
	for i := 0; i < maxRetiredBuilds+4; i++ {
		many = append(many, "old-"+strconv.Itoa(i))
	}
	bounded := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "bX", RetiredBuilds: many}, "bY", "")
	if len(bounded) != maxRetiredBuilds {
		t.Fatalf("lineage should be bounded to %d, got %d", maxRetiredBuilds, len(bounded))
	}
	if bounded[0] == "old-0" {
		t.Fatal("oldest entry should be dropped first")
	}
}

// The HTTP upsert path persists lineage: finishing a rollout (previous cleared)
// moves the old build into retired_builds, and the registry gate then matches a
// returning provider that only advertises the retired build.
func TestListModelsHidesRetiredAliasBuild(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{})
	srv := New(registry.New(logger), st, nil, readcache.New(), logger, Hooks{})

	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B (fp8)")
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B (qat-4bit)")
	// Fully retired: desired=qat, previous cleared, fp8 in the retired lineage
	// (still registered + active in the catalog — the exact leak condition).
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, RetiredBuilds: []string{aliasFP8},
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	rec := httptest.NewRecorder()
	srv.HandleListModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	sawAlias, leakedFP8, leakedQAT := false, false, false
	for _, m := range resp.Data {
		switch m.ID {
		case "gemma-4-26b":
			sawAlias = true
		case aliasFP8:
			leakedFP8 = true
		case aliasQAT:
			leakedQAT = true
		}
	}
	if !sawAlias {
		t.Fatalf("alias gemma-4-26b missing from /v1/models: %+v", resp.Data)
	}
	if leakedFP8 {
		t.Fatalf("retired build %q leaked into /v1/models — consumers must only ever see the alias", aliasFP8)
	}
	if leakedQAT {
		t.Fatalf("desired build %q leaked into /v1/models", aliasQAT)
	}

	// The hidden set covers the retired build directly too.
	_, registryByID, err := srv.activeCatalogLookups()
	if err != nil {
		t.Fatal(err)
	}
	catalogByID := map[string]store.SupportedModel{aliasFP8: {ID: aliasFP8, Active: true, ModelType: "text"}, aliasQAT: {ID: aliasQAT, Active: true, ModelType: "text"}}
	_, hidden := srv.aliasModelEntries(map[string]*registry.ModelCapacity{}, catalogByID, registryByID)
	if _, ok := hidden[aliasFP8]; !ok {
		t.Fatalf("retired build should be in the hidden set: %v", hidden)
	}
}

// TestModelAliasTakeoverOfConcreteID covers the 8-bit→4-bit public-name cutover:
// an alias adopts the live concrete id "gemma-4-26b", absorbing it as the
// previous/fallback build while pointing desired at the new 4-bit build. The
// critical safety property is that the absorbed model's catalog weight hash is
// untouched, so the providers already serving it are not untrusted.
func TestStandardAliasCoversEveryBuildState(t *testing.T) {
	for name, alias := range map[string]store.ModelAlias{
		"desired":  {Active: true, DesiredBuild: "source"},
		"previous": {Active: true, PreviousBuild: "source"},
		"retired":  {Active: true, RetiredBuilds: []string{"source"}},
	} {
		t.Run(name, func(t *testing.T) {
			if !standardAliasCoversBuild(alias, "source") {
				t.Fatalf("%s build was not covered: %+v", name, alias)
			}
		})
	}
}
