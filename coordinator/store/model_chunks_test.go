package store

import (
	"strings"
	"testing"
)

func TestModelChunksMemoryAndCache(t *testing.T)   { testModelChunksStore(t, NewMemory(Config{})) }
func TestModelChunksPostgresAndCache(t *testing.T) { testModelChunksStore(t, testPostgresStore(t)) }

func testModelChunksStore(t *testing.T, backing Store) {
	t.Helper()
	cached := NewCached(backing, DefaultCacheConfig())
	id := uniqueID("chunk-model")
	entry := &ModelRegistryEntry{ID: id, Status: "active", Capabilities: []string{}, RequiredProviderCapabilities: []string{"r2_chunked_downloads"}}
	version := &ModelVersion{ModelID: id, Version: "v1", R2Prefix: "v2/test/v1", Status: "ready", AggregateSHA256: strings.Repeat("a", 64), FileCount: 1, TotalSizeBytes: 2}
	files := []ModelVersionFile{{Path: "model.safetensors", SizeBytes: 2, SHA256: strings.Repeat("b", 64), Role: "weight",
		R2Chunks: []ManifestChunk{{SizeBytes: 2, SHA256: strings.Repeat("b", 64)}}}}
	if err := cached.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	if err := cached.PromoteModelVersion(id, "v1"); err != nil {
		t.Fatal(err)
	}
	files[0].R2Chunks[0].SizeBytes = 99
	m, err := cached.GetModelManifest(id)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Files[0].R2Chunks) != 1 || m.Files[0].R2Chunks[0].SizeBytes != 2 {
		t.Fatalf("lost or aliased chunks: %+v", m)
	}
	listed, err := backing.ListActiveModelRegistryWithError()
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, record := range listed {
		if record.ID == id {
			found = true
			if len(record.Files) != 1 || len(record.Files[0].R2Chunks) != 1 || record.Files[0].R2Chunks[0].SizeBytes != 2 {
				t.Fatalf("batch catalog load lost chunk metadata: %+v", record.Files)
			}
		}
	}
	if !found {
		t.Fatal("published model missing from batch catalog load")
	}
	m.Files[0].R2Chunks[0].SizeBytes = 88
	rec, err := cached.GetModelRegistryRecord(id)
	if err != nil {
		t.Fatal(err)
	}
	rec.Files[0].R2Chunks[0].SizeBytes = 77
	again, err := cached.GetModelManifest(id)
	if err != nil || again.Files[0].R2Chunks[0].SizeBytes != 2 {
		t.Fatal("manifest aliases store/cache", err)
	}
	files[0].R2Chunks = nil
	if err := cached.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	again, err = cached.GetModelManifest(id)
	if err != nil || len(again.Files[0].R2Chunks) != 0 {
		t.Fatal("stale chunk metadata after re-registration", err)
	}
}
