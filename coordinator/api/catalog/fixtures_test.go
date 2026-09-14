package catalog

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const testHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const (
	aliasFP8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	aliasQAT = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
)

func seedActiveModel(t *testing.T, st store.Store, modelID, displayName string) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: displayName, Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 8192, MinRAMGB: 24,
		Capabilities: []string{"chat"}, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: modelID, Version: "v1", R2Prefix: ModelR2Prefix(modelID, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
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
		R2Prefix:        ModelR2Prefix("mlx-community/test", "v1"),
		AggregateSHA256: aggregateManifestFileHashes(files),
		TotalSizeBytes:  123,
		FileCount:       1,
		Files:           files,
		CreatedAt:       time.Now(),
	}
}

func containsStr(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
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
