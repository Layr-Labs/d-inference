package catalog

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCatalogAliasesForResponse(t *testing.T) {
	models := []map[string]any{
		{"id": "gemma-4-26b-qat-4bit"},
		{"id": "gemma-4-26b"},
	}
	aliases := []store.ModelAlias{
		{
			AliasID:       "gemma-4-26b",
			DisplayName:   "Gemma 4 26B",
			DesiredBuild:  "gemma-4-26b-qat-4bit",
			PreviousBuild: "gemma-4-26b",
			RetiredBuilds: []string{"gemma-4-26b-old"},
			Active:        true,
		},
		{AliasID: "inactive", DesiredBuild: "missing", Active: false},
	}

	got := catalogAliasesForResponse(models, aliases)
	if len(got) != 1 {
		t.Fatalf("alias count = %d, want 1", len(got))
	}
	alias := got[0]
	if alias["id"] != "gemma-4-26b" || alias["display_name"] != "Gemma 4 26B" {
		t.Fatalf("unexpected alias identity: %#v", alias)
	}
	if alias["desired_build"] != "gemma-4-26b-qat-4bit" || alias["previous_build"] != "gemma-4-26b" {
		t.Fatalf("unexpected alias builds: %#v", alias)
	}
	if alias["primary_build"] != "gemma-4-26b-qat-4bit" {
		t.Fatalf("primary_build = %v, want desired", alias["primary_build"])
	}
	retired, ok := alias["retired_builds"].([]string)
	if !ok || len(retired) != 1 || retired[0] != "gemma-4-26b-old" {
		t.Fatalf("retired_builds = %#v", alias["retired_builds"])
	}
}

func TestModelCatalogRejectsAliasCacheKeyCollisionType(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := newTestController(registry.New(logger), st, logger)
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B (qat-4bit)")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT,
	}); err != nil {
		t.Fatal(err)
	}

	bad := httptest.NewRecorder()
	srv.ListInstallCatalog(bad, httptest.NewRequest(http.MethodGet, "/v1/models/catalog?type=text:include_aliases=true", nil))
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("collision-shaped type status = %d, want 400 (body=%s)", bad.Code, bad.Body.String())
	}

	good := httptest.NewRecorder()
	srv.ListInstallCatalog(good, httptest.NewRequest(http.MethodGet, "/v1/models/catalog?type=text&include_aliases=true", nil))
	if good.Code != http.StatusOK {
		t.Fatalf("catalog status = %d body=%s", good.Code, good.Body.String())
	}
	var resp struct {
		Models  []map[string]any `json:"models"`
		Aliases []map[string]any `json:"aliases"`
	}
	if err := json.Unmarshal(good.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Models) != 1 || len(resp.Aliases) != 1 {
		t.Fatalf("legitimate alias catalog was lost after rejected collision key: models=%#v aliases=%#v", resp.Models, resp.Aliases)
	}
}

func TestParseModelCatalogPathsDisambiguatesManifestSuffix(t *testing.T) {
	modelID, ok := parseModelCatalogPath("/v1/models/catalog/org/manifest")
	if !ok || modelID != "org/manifest" {
		t.Fatalf("expected catalog item path to preserve /manifest model id, got %q ok=%v", modelID, ok)
	}
	manifestID, ok := parseModelCatalogManifestPath("/v1/models/catalog/manifest/org%2Fmanifest")
	if !ok || manifestID != "org/manifest" {
		t.Fatalf("expected manifest route to decode model id, got %q ok=%v", manifestID, ok)
	}
}

func TestModelRegistryNotFoundClassification(t *testing.T) {
	if !isModelRegistryNotFound(fmt.Errorf("model %q not found", "x")) {
		t.Fatal("expected not found error to classify as not found")
	}
	if isModelRegistryNotFound(fmt.Errorf("store: get model registry record: connection refused")) {
		t.Fatal("expected DB error not to classify as not found")
	}
}
