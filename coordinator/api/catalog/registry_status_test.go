package catalog

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRegisteringNewVersionPreservesRetiredStatus(t *testing.T) {
	st := store.NewMemory(store.Config{})
	entry := &store.ModelRegistryEntry{ID: "mlx-community/retired", DisplayName: "Retired", Status: "retired", Quantization: "8bit", MaxContextLength: 32768, MaxOutputLength: 8192, MinRAMGB: 32}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: entry.ID, Version: "v1", R2Prefix: ModelR2Prefix(entry.ID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(entry.ID, "v1"); err != nil {
		t.Fatal(err)
	}

	entry.Status = "beta"
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: entry.ID, Version: "v2", R2Prefix: ModelR2Prefix(entry.ID, "v2"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(entry.ID, "v2"); err != nil {
		t.Fatal(err)
	}
	if active := st.ListActiveModelRegistry(); len(active) != 0 {
		t.Fatalf("expected retired model to remain hidden after registering a new version, got %#v", active)
	}
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
