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

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRegisterChunkedModelActiveTransportLifecycle(t *testing.T) {
	legacy := validTestManifest()
	chunked := validTestManifest()
	chunked.Version = "chunked"
	chunked.R2Prefix = modelR2Prefix(chunked.ModelID, chunked.Version)
	chunked.Files[0].R2Chunks = []store.ManifestChunk{{SizeBytes: 123, SHA256: testHash}}
	replacement := validTestManifest()
	replacement.Version = "replacement"
	replacement.R2Prefix = modelR2Prefix(replacement.ModelID, replacement.Version)
	manifests := []*store.ModelManifest{legacy, chunked, replacement}
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, manifest := range manifests {
			if r.URL.Path == "/"+manifest.R2Prefix+"/manifest.json" {
				writeJSON(w, http.StatusOK, manifest)
				return
			}
			object := "/" + manifest.R2Prefix + "/config.json"
			if len(manifest.Files[0].R2Chunks) > 0 {
				object += ".chunks/000000.bin"
			}
			if r.Method == http.MethodHead && r.URL.Path == object {
				w.Header().Set("Content-Length", "123")
				return
			}
		}
		http.NotFound(w, r)
	}))
	defer cdn.Close()
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdn.URL)
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "test-publish-key")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	backing := store.NewCached(store.NewMemory(store.Config{}), store.DefaultCacheConfig())
	reg := registry.New(logger)
	srv := NewServer(reg, backing, ServerConfig{}, logger)
	reg.Register("legacy-provider", nil, &protocol.RegisterMessage{})
	post := func(path string, value any) {
		t.Helper()
		body, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer test-publish-key")
		response := httptest.NewRecorder()
		srv.Handler().ServeHTTP(response, r)
		if response.Code != http.StatusOK {
			t.Fatalf("%s failed: %d %s", path, response.Code, response.Body.String())
		}
	}
	register := func(manifest *store.ModelManifest, promote bool) {
		t.Helper()
		req := registerModelRequest{ModelID: manifest.ModelID, Version: manifest.Version,
			Quantization: "4bit", MaxContextLength: 8192, MaxOutputLength: 1024,
			MinRAMGB: 8, InputPrice: 1, OutputPrice: 1, Promote: promote}
		if len(manifest.Files[0].R2Chunks) > 0 {
			req.RequiredProviderCapabilities = []string{registry.ProviderCapabilityR2Chunks}
		}
		post("/v1/admin/models/register", req)
	}
	promote := func(version string) {
		t.Helper()
		post("/v1/admin/models/mlx-community%2Ftest/promote", map[string]string{"version": version})
	}
	check := func(version string, requiresChunks bool) {
		t.Helper()
		record, err := backing.GetModelRegistryRecord(legacy.ModelID)
		if err != nil {
			t.Fatal(err)
		}
		if record.ActiveVersion.Version != version {
			t.Fatalf("active version = %s, want %s", record.ActiveVersion.Version, version)
		}
		want := []string{}
		if requiresChunks {
			want = append(want, registry.ProviderCapabilityR2Chunks)
		}
		if got := catalogModelFromRegistryRecord(record)["required_provider_capabilities"]; !reflect.DeepEqual(got, want) {
			t.Errorf("public catalog capabilities = %v, want %v", got, want)
		}
		if got := supportedModelFromRegistryRecord(record).RequiredProviderCapabilities; !reflect.DeepEqual(got, want) {
			t.Errorf("supported model capabilities = %v, want %v", got, want)
		}
		// Exercise the actual registry populated by SyncModelCatalog, not only
		// the public response helper: unsupported providers must be rejected.
		merged, _ := reg.MergeProviderModels("legacy-provider", []protocol.ModelInfo{{
			ID: legacy.ModelID, WeightHash: legacy.AggregateSHA256,
		}})
		if got := len(merged) > 0; got == requiresChunks {
			t.Errorf("legacy provider accepted = %v, active version requires chunks = %v", got, requiresChunks)
		}
	}

	register(legacy, true)
	check(legacy.Version, false)
	register(chunked, false)
	check(legacy.Version, false) // staging must not remove usable legacy capacity
	promote(chunked.Version)
	check(chunked.Version, true)
	promote(legacy.Version)
	check(legacy.Version, false) // rollback must clear stale model-level chunk requirements
	promote(chunked.Version)
	register(replacement, false)
	check(chunked.Version, true) // staging must not admit providers unable to reconstruct chunks
	promote(replacement.Version)
	check(replacement.Version, false)
}

func TestManifestChunksCapabilitiesPreserveOtherRequirements(t *testing.T) {
	configured := []string{registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityR2Chunks, registry.ProviderCapabilityMLXNAX}
	for _, chunked := range []bool{false, true} {
		record := &store.ModelRegistryRecord{ModelRegistryEntry: store.ModelRegistryEntry{
			RequiredProviderCapabilities: append([]string{}, configured...),
		}}
		want := []string{registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityMLXNAX}
		if chunked {
			record.Files = []store.ModelVersionFile{{R2Chunks: chunkManifest().Files[0].R2Chunks}}
			want = append(want, registry.ProviderCapabilityR2Chunks)
		}
		if got := modelTransportCapabilities(record); !reflect.DeepEqual(got, want) {
			t.Errorf("chunked=%v: capabilities = %v, want %v", chunked, got, want)
		}
		if !reflect.DeepEqual(record.RequiredProviderCapabilities, configured) {
			t.Fatal("deriving transport requirements mutated the stored operator metadata")
		}
	}
}
