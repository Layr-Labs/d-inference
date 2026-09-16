package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRegisterChunkedModelStagesBeforePromotion(t *testing.T) {
	manifest := validTestManifest()
	manifest.Files[0].R2Chunks = []store.ManifestChunk{
		{SizeBytes: 60, SHA256: testHash}, {SizeBytes: 63, SHA256: testHash},
	}
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/" + manifest.R2Prefix + "/manifest.json":
			writeJSON(w, http.StatusOK, manifest)
		case "/" + manifest.R2Prefix + "/config.json.chunks/000000.bin":
			w.Header().Set("Content-Length", "60")
		case "/" + manifest.R2Prefix + "/config.json.chunks/000001.bin":
			w.Header().Set("Content-Length", "63")
		default:
			http.NotFound(w, r) // There is deliberately no original-file R2 object.
		}
	}))
	defer cdn.Close()
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdn.URL)
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "test-publish-key")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	backing := store.NewCached(store.NewMemory(store.Config{}), store.DefaultCacheConfig())
	reg := registry.New(logger)
	srv := NewServer(reg, backing, ServerConfig{}, logger)
	req := registerModelRequest{ModelID: manifest.ModelID, Version: manifest.Version,
		Quantization: "4bit", MaxContextLength: 8192, MaxOutputLength: 1024,
		MinRAMGB: 8, InputPrice: 1, OutputPrice: 1, Promote: false}
	post := func(path string, value any) *httptest.ResponseRecorder {
		t.Helper()
		body, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer test-publish-key")
		response := httptest.NewRecorder()
		srv.Handler().ServeHTTP(response, r)
		return response
	}
	if response := post("/v1/admin/models/register", req); response.Code != http.StatusBadRequest {
		t.Fatalf("missing capability accepted: %d %s", response.Code, response.Body.String())
	}
	req.RequiredProviderCapabilities = []string{registry.ProviderCapabilityR2Chunks}
	if response := post("/v1/admin/models/register", req); response.Code != http.StatusOK {
		t.Fatalf("register failed: %d %s", response.Code, response.Body.String())
	}
	if reg.IsModelInCatalog(req.ModelID) {
		t.Fatal("registration without promotion activated the new model")
	}
	if response := post("/v1/admin/models/mlx-community%2Ftest/promote", map[string]string{"version": "v1"}); response.Code != http.StatusOK {
		t.Fatalf("promotion failed: %d %s", response.Code, response.Body.String())
	}
	if !reg.IsModelInCatalog(req.ModelID) {
		t.Fatal("promoted model not in routing catalog")
	}
	stored, err := backing.GetModelManifest(req.ModelID)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(stored.Files, manifest.Files) || stored.AggregateSHA256 != manifest.AggregateSHA256 {
		t.Fatal("registration lost chunk metadata or changed the original model hash")
	}
	record, err := backing.GetModelRegistryRecord(req.ModelID)
	if err != nil {
		t.Fatal(err)
	}
	catalog := catalogModelFromRegistryRecord(record)
	if _, ok := catalog["hugging_face_artifact"]; ok {
		t.Fatal("R2-only version unexpectedly acquired an HF source")
	}
	if !reflect.DeepEqual(catalog["required_provider_capabilities"], req.RequiredProviderCapabilities) {
		t.Fatal("catalog dropped chunk capability requirement")
	}
}
