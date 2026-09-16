package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestManifestChunksCapabilitiesFollowActiveTransport(t *testing.T) {
	backing := store.NewMemory(store.Config{})
	entry := &store.ModelRegistryEntry{ID: "test/chunks", Status: "active"}
	chunked := &store.ModelVersion{ModelID: entry.ID, Version: "chunked", Status: "ready"}
	files := []store.ModelVersionFile{{Path: "weights.safetensors", SizeBytes: 7, R2Chunks: chunkManifest().Files[0].R2Chunks}}
	if err := backing.SetModelVersion(entry, chunked, files); err != nil {
		t.Fatal(err)
	}
	if err := backing.PromoteModelVersion(entry.ID, chunked.Version); err != nil {
		t.Fatal(err)
	}
	// Registering an unchunked replacement updates model-level metadata even
	// without promotion. Both public catalog and scheduling must stay gated.
	legacy := &store.ModelVersion{ModelID: entry.ID, Version: "legacy", Status: "ready"}
	if err := backing.SetModelVersion(entry, legacy, []store.ModelVersionFile{{Path: "weights.safetensors", SizeBytes: 7}}); err != nil {
		t.Fatal(err)
	}
	check := func(want []string) {
		t.Helper()
		rec, err := backing.GetModelRegistryRecord(entry.ID)
		if err != nil {
			t.Fatal(err)
		}
		catalog := catalogModelFromRegistryRecord(rec)["required_provider_capabilities"]
		scheduling := supportedModelFromRegistryRecord(rec).RequiredProviderCapabilities
		if !reflect.DeepEqual(catalog, want) || !reflect.DeepEqual(scheduling, want) {
			t.Fatalf("catalog=%v scheduling=%v want=%v", catalog, scheduling, want)
		}
		if len(rec.RequiredProviderCapabilities) != 0 {
			t.Fatal("derived requirements mutated stored metadata")
		}
	}
	check([]string{registry.ProviderCapabilityR2Chunks})
	if err := backing.PromoteModelVersion(entry.ID, legacy.Version); err != nil {
		t.Fatal(err)
	}
	check([]string{})
	if err := backing.PromoteModelVersion(entry.ID, chunked.Version); err != nil {
		t.Fatal(err)
	}
	check([]string{registry.ProviderCapabilityR2Chunks})
}

func chunkManifest() *store.ModelManifest {
	return &store.ModelManifest{Files: []store.ManifestFile{{Path: "weights.safetensors", SizeBytes: 7,
		R2Chunks: []store.ManifestChunk{{SizeBytes: 3, SHA256: strings.Repeat("a", 64)}, {SizeBytes: 4, SHA256: strings.Repeat("b", 64)}}}}}
}

func TestManifestChunksValidation(t *testing.T) {
	if err := validateManifestChunks(chunkManifest()); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*store.ModelManifest){
		func(m *store.ModelManifest) { m.Files[0].R2Chunks = []store.ManifestChunk{} },
		func(m *store.ModelManifest) { m.Files[0].R2Chunks[0].SizeBytes = 500_000_000 },
		func(m *store.ModelManifest) { m.Files[0].R2Chunks[0].SizeBytes = 0 },
		func(m *store.ModelManifest) { m.Files[0].R2Chunks[0].SizeBytes = 2 },
		func(m *store.ModelManifest) { m.Files[0].R2Chunks[0].SHA256 = "bad" },
		func(m *store.ModelManifest) {
			m.Files = append(m.Files, store.ManifestFile{Path: "WEIGHTS.safetensors.chunks/000000.bin"})
		},
		func(m *store.ModelManifest) {
			m.Files = append(m.Files, store.ManifestFile{Path: "weights.safetensors.r2-transfer/assembled"})
		},
	} {
		m := chunkManifest()
		mutate(m)
		if err := validateManifestChunks(m); err == nil {
			t.Fatalf("accepted malformed chunks: %+v", m.Files)
		}
	}
	if err := validateChunkCapability(chunkManifest(), nil); err == nil {
		t.Fatal("missing capability accepted")
	}
	if err := validateChunkCapability(chunkManifest(), []string{registry.ProviderCapabilityR2Chunks}); err != nil {
		t.Fatal(err)
	}
}

func TestManifestChunksVerifyObjectsInsteadOfOriginal(t *testing.T) {
	paths := make(chan string, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead {
			t.Errorf("unexpected method %s", r.Method)
		}
		paths <- r.URL.Path
		switch r.URL.Path {
		case "/v2/test/weights.safetensors.chunks/000000.bin":
			w.Header().Set("Content-Length", "3")
		case "/v2/test/weights.safetensors.chunks/000001.bin":
			w.Header().Set("Content-Length", "4")
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	m := chunkManifest()
	m.R2Prefix = "v2/test"
	if err := verifyManifestFiles(context.Background(), server.URL, m, nil); err != nil {
		t.Fatal(err)
	}
	if len(paths) != 2 {
		t.Fatalf("expected 2 chunk HEADs, got %d", len(paths))
	}
}
