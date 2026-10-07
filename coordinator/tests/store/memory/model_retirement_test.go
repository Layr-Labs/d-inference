package memory_test

import (
	"crypto/sha256"
	"fmt"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	production "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestRegisteringNewVersionPreservesRetiredStatus(t *testing.T) {
	st := production.NewMemory(store.Config{})
	entry := &store.ModelRegistryEntry{ID: "mlx-community/retired", DisplayName: "Retired", Status: "retired", Quantization: "8bit", MaxContextLength: 32768, MaxOutputLength: 8192, MinRAMGB: 32}
	hash := strings.Repeat("a", 64)
	sum := sha256.Sum256([]byte(entry.ID))
	prefix := fmt.Sprintf("v2/mlx-community-retired--%x/", sum[:6])
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: hash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: entry.ID, Version: "v1", R2Prefix: prefix + "v1", AggregateSHA256: hash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(entry.ID, "v1"); err != nil {
		t.Fatal(err)
	}
	entry.Status = "beta"
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: entry.ID, Version: "v2", R2Prefix: prefix + "v2", AggregateSHA256: hash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(entry.ID, "v2"); err != nil {
		t.Fatal(err)
	}
	if active, err := st.ListActiveModelRegistryWithError(); err != nil || len(active) != 0 {
		t.Fatalf("expected retired model to remain hidden after registering a new version, got %#v (err %v)", active, err)
	}
}

func TestUpsertModelRegistryEntryPreservesExistingStatus(t *testing.T) {
	st := production.NewMemory(store.Config{})
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
