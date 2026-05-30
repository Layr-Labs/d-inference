package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const testHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func TestValidateModelManifestRejectsTraversalAndBadHashes(t *testing.T) {
	prefix := modelR2Prefix("mlx-community/test", "v1")
	manifest := validTestManifest()
	manifest.Files[0].Path = "weights/../config.json"
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected traversal path to be rejected")
	}

	manifest = validTestManifest()
	manifest.AggregateSHA256 = "ABC"
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected bad aggregate hash to be rejected")
	}

	manifest = validTestManifest()
	manifest.AggregateSHA256 = testHash
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected mismatched aggregate hash to be rejected")
	}

	manifest = validTestManifest()
	manifest.Files[0].SHA256 = "bbbb"
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected bad file hash to be rejected")
	}

	manifest = validTestManifest()
	manifest.TotalSizeBytes = 999
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected mismatched total_size_bytes to be rejected")
	}

	manifest = validTestManifest()
	manifest.Files = nil
	manifest.FileCount = 0
	manifest.TotalSizeBytes = 0
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected empty manifest to be rejected")
	}

	manifest = validTestManifest()
	manifest.Files = append(manifest.Files, manifest.Files[0])
	manifest.FileCount = 2
	manifest.TotalSizeBytes = 246
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected duplicate manifest paths to be rejected")
	}

	manifest = validTestManifest()
	caseCollidingFile := manifest.Files[0]
	caseCollidingFile.Path = "Config.json"
	manifest.Files = append(manifest.Files, caseCollidingFile)
	manifest.FileCount = 2
	manifest.TotalSizeBytes = 246
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected case-colliding manifest paths to be rejected")
	}

	for _, badPath := range []string{"a//b", "./x", "x/.", "x/../y"} {
		manifest = validTestManifest()
		manifest.Files[0].Path = badPath
		if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
			t.Fatalf("expected path %q to be rejected", badPath)
		}
	}
}

func TestRegisterValidationAndR2Prefix(t *testing.T) {
	for _, req := range []registerModelRequest{
		{ModelID: "bad id", Version: "v1"},
		{ModelID: "../bad", Version: "v1"},
		{ModelID: "ok/model", Version: "bad/version"},
		{ModelID: "ok/model", Version: "bad..version"},
		{ModelID: "ok/model", Version: "v1", Quantization: "", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 1},
		{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 0, MaxOutputLength: 1, MinRAMGB: 1},
		{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 0, MinRAMGB: 1},
		{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 0},
	} {
		if err := validateRegisterModelRequest(req); err == nil {
			t.Fatalf("expected invalid request to fail: %#v", req)
		}
	}
	// Verify missing pricing is rejected.
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 1, InputPrice: 0, OutputPrice: 100}); err == nil {
		t.Fatal("expected missing input_price to fail")
	}
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 1, InputPrice: 100, OutputPrice: 0}); err == nil {
		t.Fatal("expected missing output_price to fail")
	}
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "mlx-community/gemma-4-26b-a4b-it-8bit", Version: "2026-05-23-r1", Quantization: "8bit", MaxContextLength: 32768, MaxOutputLength: 8192, MinRAMGB: 36, InputPrice: 30000, OutputPrice: 165000}); err != nil {
		t.Fatalf("expected valid request: %v", err)
	}
	if modelR2Prefix("foo/bar", "v1") == modelR2Prefix("foo__bar", "v1") {
		t.Fatal("modelR2Prefix must not collide for slash vs underscore model IDs")
	}
	if got := modelR2Prefix("mlx-community/openai-gpt-oss-20b", "2026-05-23-r1"); got != "v2/mlx-community-openai-gpt-oss-20b--8f458c9d97d4/2026-05-23-r1" {
		t.Fatalf("unexpected human-readable R2 prefix: %s", got)
	}
	if got := modelR2Prefix("foo/bar", "v1"); got != "v2/foo-bar--cc5d46bdb499/v1" {
		t.Fatalf("unexpected slash slug prefix: %s", got)
	}
	if got := modelR2Prefix("foo__bar", "v1"); got != "v2/foo__bar--a3a759156e88/v1" {
		t.Fatalf("unexpected underscore slug prefix: %s", got)
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

func TestRegisterModelHandlerPromotesActiveRecord(t *testing.T) {
	manifest := validTestManifest()
	prefix := modelR2Prefix("mlx-community/test", "v1")
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
		"model_id":           "mlx-community/test",
		"version":            "v1",
		"display_name":       "Test Model",
		"family":             "qwen",
		"architecture":       "dense",
		"quantization":       "4bit",
		"max_context_length": 32768,
		"max_output_length":  8192,
		"min_ram_gb":         16,
		"capabilities":       []string{"chat"},
		"description":        "test",
		"runtime_parameters": map[string]any{"default_temperature": 0, "chat_template_required": true},
		"metadata":           map[string]any{"tier": "test"},
		"promote":            true,
		"input_price":        50000,
		"output_price":       200000,
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
	version := &store.ModelVersion{ModelID: entry.ID, Version: "v1", R2Prefix: modelR2Prefix(entry.ID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 2_000_000_000, FileCount: 1, Status: "ready"}
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
	srv.handleListModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("list models status = %d body = %s", rec.Code, rec.Body.String())
	}

	srv.SyncModelCatalog()
	if !reg.IsModelInCatalog("sentinel") || reg.IsModelInCatalog("legacy") {
		t.Fatal("expected sync error to preserve existing catalog without falling back to legacy catalog")
	}
}

func TestPublishingAPIKeyStoreErrorSurfacesButBootstrapStillWorks(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := &failingModelRegistryStore{MemoryStore: store.NewMemory(store.Config{}), keyErr: errors.New("database unavailable")}
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "")
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", nil)
	req.Header.Set("Authorization", "Bearer db-key")
	rec := httptest.NewRecorder()
	if _, ok := srv.requirePublishingAPIKey(rec, req); ok {
		t.Fatal("expected DB-backed key lookup to fail")
	}
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("auth failure status = %d body = %s", rec.Code, rec.Body.String())
	}

	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "bootstrap")
	req = httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", nil)
	req.Header.Set("Authorization", "Bearer bootstrap")
	rec = httptest.NewRecorder()
	if actor, ok := srv.requirePublishingAPIKey(rec, req); !ok || actor.ID != "env-bootstrap" {
		t.Fatalf("expected bootstrap key to bypass DB, actor=%#v ok=%v", actor, ok)
	}
}

func TestRegisteringNewVersionPreservesRetiredStatus(t *testing.T) {
	st := store.NewMemory(store.Config{})
	entry := &store.ModelRegistryEntry{ID: "mlx-community/retired", DisplayName: "Retired", Status: "retired", Quantization: "8bit", MaxContextLength: 32768, MaxOutputLength: 8192, MinRAMGB: 32}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: entry.ID, Version: "v1", R2Prefix: modelR2Prefix(entry.ID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(entry.ID, "v1"); err != nil {
		t.Fatal(err)
	}

	entry.Status = "beta"
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: entry.ID, Version: "v2", R2Prefix: modelR2Prefix(entry.ID, "v2"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(entry.ID, "v2"); err != nil {
		t.Fatal(err)
	}
	if active := st.ListActiveModelRegistry(); len(active) != 0 {
		t.Fatalf("expected retired model to remain hidden after registering a new version, got %#v", active)
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

func TestUpsertModelRegistryEntryPreservesExistingStatus(t *testing.T) {
	st := store.NewMemory(store.Config{})
	entry := &store.ModelRegistryEntry{ID: "mlx-community/upsert", DisplayName: "Upsert", Status: "retired", Quantization: "8bit", MaxContextLength: 32768, MaxOutputLength: 8192, MinRAMGB: 32}
	if err := st.UpsertModelRegistryEntry(entry); err != nil {
		t.Fatal(err)
	}
	entry.Status = "beta"
	entry.DisplayName = "Updated"
	if err := st.UpsertModelRegistryEntry(entry); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetModelRegistryRecord(entry.ID); err == nil {
		t.Fatal("expected retired model to remain hidden after upsert")
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
		R2Prefix:        modelR2Prefix("mlx-community/test", "v1"),
		AggregateSHA256: aggregateManifestFileHashes(files),
		TotalSizeBytes:  123,
		FileCount:       1,
		Files:           files,
		CreatedAt:       time.Now(),
	}
}
