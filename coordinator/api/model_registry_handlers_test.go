package api

import (
	"bytes"
	"encoding/json"
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
	manifest.Files[0].SHA256 = "bbbb"
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected bad file hash to be rejected")
	}

	manifest = validTestManifest()
	manifest.TotalSizeBytes = 999
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected mismatched total_size_bytes to be rejected")
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
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "mlx-community/gemma-4-26b-a4b-it-8bit", Version: "2026-05-23-r1", Quantization: "8bit", MaxContextLength: 32768, MaxOutputLength: 8192, MinRAMGB: 36}); err != nil {
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
	st := store.NewMemory("")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
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
		"metadata":           map[string]any{"tier": "test"},
		"promote":            true,
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

func TestModelCatalogFallbackAndRegistryPreference(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	if err := st.SetSupportedModel(&store.SupportedModel{ID: "legacy", DisplayName: "Legacy", ModelType: "text", Active: true, WeightHash: testHash, SizeGB: 1}); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/models/catalog", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	var legacy struct {
		Models []store.SupportedModel `json:"models"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &legacy); err != nil {
		t.Fatalf("decode legacy catalog: %v", err)
	}
	if len(legacy.Models) != 1 || legacy.Models[0].ID != "legacy" {
		t.Fatalf("expected legacy fallback, got %#v", legacy.Models)
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
	if !reg.IsModelInCatalog(entry.ID) || reg.IsModelInCatalog("legacy") {
		t.Fatal("expected synced routing catalog to prefer new registry rows")
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

func validTestManifest() *store.ModelManifest {
	return &store.ModelManifest{
		SchemaVersion:   1,
		ModelID:         "mlx-community/test",
		Version:         "v1",
		R2Prefix:        modelR2Prefix("mlx-community/test", "v1"),
		AggregateSHA256: testHash,
		TotalSizeBytes:  123,
		FileCount:       1,
		Files: []store.ManifestFile{{
			Path:      "config.json",
			SizeBytes: 123,
			SHA256:    testHash,
			Role:      "config",
		}},
		CreatedAt: time.Now(),
	}
}
