package catalog

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
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
	srv := newTestController(registry.New(logger), st, logger)

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

	entries, hidden, err := srv.aliasModelEntries(capByModel, catalogByID, registryByID)
	if err != nil {
		t.Fatal(err)
	}
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
	srv := newTestController(registry.New(logger), st, logger)

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
	entries, hidden, err := srv.aliasModelEntries(map[string]*registry.ModelCapacity{}, catalogByID, registryByID)
	if err != nil {
		t.Fatal(err)
	}
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

// After full retirement (previous_build cleared, the old build moved into the
// retired lineage but still a registered/active model), /v1/models must STILL
// show only the alias — never the raw retired quant. Regression for the
// retired-build listing leak: a consumer must only ever see the alias.
func TestListModelsHidesRetiredAliasBuild(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := newTestController(registry.New(logger), st, logger)

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
	srv.Invalidate()

	rec := httptest.NewRecorder()
	srv.ListModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
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
	_, hidden, err := srv.aliasModelEntries(map[string]*registry.ModelCapacity{}, catalogByID, registryByID)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := hidden[aliasFP8]; !ok {
		t.Fatalf("retired build should be in the hidden set: %v", hidden)
	}
}
