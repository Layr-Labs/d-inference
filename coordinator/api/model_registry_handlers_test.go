package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/catalog"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const testHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func TestRegisterModelHandlerPromotesActiveRecord(t *testing.T) {
	manifest := validTestManifest()
	prefix := catalog.ModelR2Prefix("mlx-community/test", "v1")
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/" + prefix + "/manifest.json":
			if r.Method != http.MethodGet {
				t.Fatalf("manifest method = %s", r.Method)
			}
			writeJSON(w, http.StatusOK, manifest)
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
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
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
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

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
	version := &store.ModelVersion{ModelID: entry.ID, Version: "v1", R2Prefix: catalog.ModelR2Prefix(entry.ID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 2_000_000_000, FileCount: 1, Status: "ready"}
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
	st := &failingModelRegistryStore{MemoryStore: store.NewMemory(store.Config{}), listErr: errors.New("database unavailable")}
	reg := registry.New(logger)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "sentinel"}})
	srv := NewServer(reg, st, ServerConfig{}, logger)

	req := httptest.NewRequest(http.MethodGet, "/v1/models/catalog", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("catalog status = %d body = %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	srv.catalogController().ListModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("list models status = %d body = %s", rec.Code, rec.Body.String())
	}

	srv.SyncModelCatalog()
	if !reg.IsModelInCatalog("sentinel") || reg.IsModelInCatalog("legacy") {
		t.Fatal("expected sync error to preserve existing catalog without falling back to legacy catalog")
	}
}

type failingModelRegistryStore struct {
	*store.MemoryStore
	listErr error
	keyErr  error
}

func (s *failingModelRegistryStore) ListActiveModelRegistryWithError() ([]store.ModelRegistryRecord, error) {
	if s.listErr != nil {
		return nil, s.listErr
	}
	return s.MemoryStore.ListActiveModelRegistryWithError()
}

func (s *failingModelRegistryStore) FindPublishingAPIKeysWithError() ([]store.PublishingAPIKey, error) {
	if s.keyErr != nil {
		return nil, s.keyErr
	}
	return s.MemoryStore.FindPublishingAPIKeysWithError()
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
		R2Prefix:        catalog.ModelR2Prefix("mlx-community/test", "v1"),
		AggregateSHA256: "e0e77a507412b120f6ede61f62295b1a7b2ff19d3dcc8f7253e51663470c888e",
		TotalSizeBytes:  123,
		FileCount:       1,
		Files:           files,
		CreatedAt:       time.Now(),
	}
}
