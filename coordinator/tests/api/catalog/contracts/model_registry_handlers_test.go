package catalog_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/api"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestModelCatalogRejectsAliasCacheKeyCollisionType(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{})
	srv := api.NewServer(registry.New(logger), st, api.ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B (qat-4bit)")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT,
	}); err != nil {
		t.Fatal(err)
	}

	bad := httptest.NewRecorder()
	srv.Handler().ServeHTTP(bad, httptest.NewRequest(http.MethodGet, "/v1/models/catalog?type=text:include_aliases=true", nil))
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("collision-shaped type status = %d, want 400 (body=%s)", bad.Code, bad.Body.String())
	}

	good := httptest.NewRecorder()
	srv.Handler().ServeHTTP(good, httptest.NewRequest(http.MethodGet, "/v1/models/catalog?type=text&include_aliases=true", nil))
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

func TestRegisterModelHandlerPromotesActiveRecord(t *testing.T) {
	manifest := validTestManifest()
	prefix := testModelPrefix("mlx-community/test", "v1")
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/" + prefix + "/manifest.json":
			if r.Method != http.MethodGet {
				t.Fatalf("manifest method = %s", r.Method)
			}
			httpx.WriteJSON(w, http.StatusOK, manifest)
		case "/" + prefix + "/config.json":
			if r.Method != http.MethodHead {
				t.Fatalf("file method = %s", r.Method)
			}
			w.Header().Set("Content-Length", "123")
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer cdn.Close()
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdn.URL)
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := api.NewServer(reg, st, api.ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	payload := map[string]any{
		"hugging_face_artifact": &store.HuggingFaceArtifact{RepoID: "EigenLabs/test", Revision: "0123456789abcdef0123456789abcdef01234567", PathPrefix: "mlx"},
		"model_id":              "mlx-community/test",
		"version":               "v1",
		"display_name":          "Test Model",
		"family":                "qwen",
		"architecture":          "dense",
		"quantization":          "4bit",
		"max_context_length":    32768,
		"max_output_length":     8192,
		"min_ram_gb":            16,
		"capabilities":          []string{"chat"},
		"description":           "test",
		"runtime_parameters":    map[string]any{"default_temperature": 0, "chat_template_required": true},
		"metadata":              map[string]any{"tier": "test"},
		"promote":               true,
		"input_price":           50000,
		"output_price":          200000,
	}
	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("register status = %d body = %s", rec.Code, rec.Body.String())
	}

	active, err := st.GetModelRegistryRecord("mlx-community/test")
	if err != nil {
		t.Fatalf("GetModelRegistryRecord: %v", err)
	}
	if active.ActiveVersion == nil || active.ActiveVersion.Version != "v1" {
		t.Fatalf("active version = %#v", active.ActiveVersion)
	}
	if active.RuntimeParameters["chat_template_required"] != true {
		t.Fatalf("runtime parameters were not stored: %#v", active.RuntimeParameters)
	}
	if !reg.IsModelInCatalog("mlx-community/test") {
		t.Fatal("expected registry routing catalog to include promoted model")
	}

	catalogReq := httptest.NewRequest(http.MethodGet, "/v1/models/catalog", nil)
	catalogRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(catalogRec, catalogReq)
	if catalogRec.Code != http.StatusOK {
		t.Fatalf("catalog status = %d", catalogRec.Code)
	}
	var catalog struct {
		Models []map[string]any `json:"models"`
	}
	if err := json.Unmarshal(catalogRec.Body.Bytes(), &catalog); err != nil {
		t.Fatalf("decode catalog: %v", err)
	}
	if len(catalog.Models) != 1 || catalog.Models[0]["id"] != "mlx-community/test" || catalog.Models[0]["version"] != "v1" {
		t.Fatalf("unexpected catalog response: %#v", catalog.Models)
	}
	artifact, ok := catalog.Models[0]["hugging_face_artifact"].(map[string]any)
	if !ok || artifact["repo_id"] != "EigenLabs/test" || artifact["revision"] != "0123456789abcdef0123456789abcdef01234567" || artifact["path_prefix"] != "mlx" {
		t.Fatalf("artifact did not round-trip registration to catalog: %#v", artifact)
	}
}

func TestModelCatalogRegistryDriven(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := api.NewServer(reg, st, api.ServerConfig{}, logger)
	t.Cleanup(srv.Close)

	// With no registry rows the catalog is empty — there is no legacy fallback.
	req := httptest.NewRequest(http.MethodGet, "/v1/models/catalog", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	var empty struct {
		Models []map[string]any `json:"models"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &empty); err != nil {
		t.Fatalf("decode empty catalog: %v", err)
	}
	if len(empty.Models) != 0 {
		t.Fatalf("expected empty catalog with no registry rows, got %#v", empty.Models)
	}

	entry := &store.ModelRegistryEntry{ID: "mlx-community/new", DisplayName: "New", Status: "active", MinRAMGB: 16, Metadata: map[string]any{}}
	version := &store.ModelVersion{ModelID: entry.ID, Version: "v1", R2Prefix: testModelPrefix(entry.ID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 2_000_000_000, FileCount: 1, Status: "ready"}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(entry.ID, "v1"); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()
	if !reg.IsModelInCatalog(entry.ID) {
		t.Fatal("expected synced routing catalog to contain the registry row")
	}

	rec = httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	var registryCatalog struct {
		Models []map[string]any `json:"models"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &registryCatalog); err != nil {
		t.Fatalf("decode registry catalog: %v", err)
	}
	if len(registryCatalog.Models) != 1 || registryCatalog.Models[0]["id"] != entry.ID {
		t.Fatalf("expected registry catalog, got %#v", registryCatalog.Models)
	}
}

func TestModelRegistryListErrorSurfacesAndDoesNotFallback(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := &failingModelRegistryStore{MemoryStore: memory.NewMemory(store.Config{AdminKey: "test-key"}), listErr: errors.New("database unavailable")}
	reg := registry.New(logger)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "sentinel"}})
	srv := api.NewServer(reg, st, api.ServerConfig{}, logger)
	t.Cleanup(srv.Close)

	req := httptest.NewRequest(http.MethodGet, "/v1/models/catalog", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("catalog status = %d body = %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, catalogRequest("/v1/models"))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("list models status = %d body = %s", rec.Code, rec.Body.String())
	}

	srv.SyncModelCatalog()
	if !reg.IsModelInCatalog("sentinel") || reg.IsModelInCatalog("legacy") {
		t.Fatal("expected sync error to preserve existing catalog without falling back to legacy catalog")
	}
}

type failingModelRegistryStore struct {
	*memory.MemoryStore
	listErr error
}

func (s *failingModelRegistryStore) ListActiveModelRegistryWithError() ([]store.ModelRegistryRecord, error) {
	if s.listErr != nil {
		return nil, s.listErr
	}
	return s.MemoryStore.ListActiveModelRegistryWithError()
}

func validTestManifest() *store.ModelManifest {
	files := []store.ManifestFile{{
		Path:      "config.json",
		SizeBytes: 123,
		SHA256:    testHash,
		Role:      "config",
	}}
	return &store.ModelManifest{
		SchemaVersion:   1,
		ModelID:         "mlx-community/test",
		Version:         "v1",
		R2Prefix:        testModelPrefix("mlx-community/test", "v1"),
		AggregateSHA256: fmt.Sprintf("%x", sha256.Sum256(bytes.Repeat([]byte{0xaa}, 32))),
		TotalSizeBytes:  123,
		FileCount:       1,
		Files:           files,
		CreatedAt:       time.Now(),
	}
}
