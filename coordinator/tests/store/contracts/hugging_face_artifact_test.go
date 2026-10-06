package store_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestHuggingFaceArtifactValidation(t *testing.T) {
	valid := store.HuggingFaceArtifact{RepoID: "EigenLabs/model-4bit", Revision: strings.Repeat("a", 40), PathPrefix: "mlx/4bit"}
	if err := valid.Validate(); err != nil {
		t.Fatal(err)
	}
	if err := (*store.HuggingFaceArtifact)(nil).Validate(); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*store.HuggingFaceArtifact){
		func(a *store.HuggingFaceArtifact) { a.RepoID = "https://huggingface.co/org/repo" },
		func(a *store.HuggingFaceArtifact) { a.RepoID = "org//repo" },
		func(a *store.HuggingFaceArtifact) { a.RepoID = "org/../repo" },
		func(a *store.HuggingFaceArtifact) { a.RepoID = "org/repo?token=x" },
		func(a *store.HuggingFaceArtifact) { a.Revision = "main" },
		func(a *store.HuggingFaceArtifact) { a.Revision = strings.Repeat("A", 40) },
		func(a *store.HuggingFaceArtifact) { a.PathPrefix = "../weights" },
		func(a *store.HuggingFaceArtifact) { a.PathPrefix = "/weights" },
		func(a *store.HuggingFaceArtifact) { a.PathPrefix = "weights/" },
		func(a *store.HuggingFaceArtifact) { a.PathPrefix = "%2e%2e" },
	} {
		a := valid
		change(&a)
		if err := a.Validate(); err == nil {
			t.Errorf("accepted invalid artifact: %+v", a)
		}
	}
}

func TestHuggingFaceArtifactMemoryAndCache(t *testing.T) {
	testHuggingFaceArtifactStore(t, memory.NewMemory(store.Config{}))
}

func TestHuggingFaceArtifactPostgresAndCache(t *testing.T) {
	testHuggingFaceArtifactStore(t, testPostgresStore(t))
}

func testHuggingFaceArtifactStore(t *testing.T, backing store.Store) {
	t.Helper()
	cached := store.NewCached(backing, store.DefaultCacheConfig())
	id := uniqueID("hf-artifact")
	entry := &store.ModelRegistryEntry{ID: id, Status: "active", Capabilities: []string{}, RequiredProviderCapabilities: []string{}}
	version := &store.ModelVersion{ModelID: id, Version: "v1", R2Prefix: "v2/test/v1", Status: "ready", AggregateSHA256: strings.Repeat("a", 64), FileCount: 1,
		HuggingFaceArtifact: &store.HuggingFaceArtifact{RepoID: "EigenLabs/test", Revision: strings.Repeat("a", 40), PathPrefix: "mlx"}}
	files := []store.ModelVersionFile{{Path: "config.json", SHA256: strings.Repeat("b", 64), Role: "config"}}
	if err := cached.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	if err := cached.PromoteModelVersion(id, "v1"); err != nil {
		t.Fatal(err)
	}
	// The backing store must own its input, and callers must not mutate the cache.
	version.HuggingFaceArtifact.RepoID = "mutated/input"
	got, err := cached.GetModelRegistryRecord(id)
	if err != nil {
		t.Fatal(err)
	}
	if got.ActiveVersion.HuggingFaceArtifact == nil || got.ActiveVersion.HuggingFaceArtifact.RepoID != "EigenLabs/test" || got.ActiveVersion.HuggingFaceArtifact.PathPrefix != "mlx" {
		t.Fatalf("artifact lost: %+v", got.ActiveVersion)
	}
	got.ActiveVersion.HuggingFaceArtifact.RepoID = "mutated/output"
	again, err := cached.GetModelRegistryRecord(id)
	if err != nil {
		t.Fatal(err)
	}
	if again.ActiveVersion.HuggingFaceArtifact.RepoID != "EigenLabs/test" {
		t.Fatal("cache aliasing")
	}
	// Re-registration clears the optional source and invalidates the cached version.
	version.HuggingFaceArtifact = nil
	if err := cached.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	again, err = cached.GetModelRegistryRecord(id)
	if err != nil {
		t.Fatal(err)
	}
	if again.ActiveVersion.HuggingFaceArtifact != nil {
		t.Fatal("stale HF source after clearing")
	}
	active, err := cached.ListActiveModelRegistryWithError()
	if err != nil {
		t.Fatal(err)
	}
	for _, record := range active {
		if record.ID == id && record.ActiveVersion.HuggingFaceArtifact != nil {
			t.Fatal("stale list source")
		}
	}
}
