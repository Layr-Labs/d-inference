package postgres

import (
	"strings"
	"testing"

	storecache "github.com/eigeninference/d-inference/coordinator/store/cache"
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestHuggingFaceArtifactValidation(t *testing.T) {
	valid := contracts.HuggingFaceArtifact{RepoID: "EigenLabs/model-4bit", Revision: strings.Repeat("a", 40), PathPrefix: "mlx/4bit"}
	if err := valid.Validate(); err != nil {
		t.Fatal(err)
	}
	if err := (*contracts.HuggingFaceArtifact)(nil).Validate(); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*contracts.HuggingFaceArtifact){
		func(a *contracts.HuggingFaceArtifact) { a.RepoID = "https://huggingface.co/org/repo" },
		func(a *contracts.HuggingFaceArtifact) { a.RepoID = "org//repo" },
		func(a *contracts.HuggingFaceArtifact) { a.RepoID = "org/../repo" },
		func(a *contracts.HuggingFaceArtifact) { a.RepoID = "org/repo?token=x" },
		func(a *contracts.HuggingFaceArtifact) { a.Revision = "main" },
		func(a *contracts.HuggingFaceArtifact) { a.Revision = strings.Repeat("A", 40) },
		func(a *contracts.HuggingFaceArtifact) { a.PathPrefix = "../weights" },
		func(a *contracts.HuggingFaceArtifact) { a.PathPrefix = "/weights" },
		func(a *contracts.HuggingFaceArtifact) { a.PathPrefix = "weights/" },
		func(a *contracts.HuggingFaceArtifact) { a.PathPrefix = "%2e%2e" },
	} {
		a := valid
		change(&a)
		if err := a.Validate(); err == nil {
			t.Errorf("accepted invalid artifact: %+v", a)
		}
	}
}

func TestHuggingFaceArtifactMemoryAndCache(t *testing.T) {
	testHuggingFaceArtifactStore(t, memory.New(contracts.Config{}))
}

func TestHuggingFaceArtifactPostgresAndCache(t *testing.T) {
	testHuggingFaceArtifactStore(t, testPostgresStore(t))
}

func testHuggingFaceArtifactStore(t *testing.T, backing contracts.Store) {
	t.Helper()
	cached := storecache.New(backing, storecache.DefaultCacheConfig())
	id := uniqueID("hf-artifact")
	entry := &contracts.ModelRegistryEntry{ID: id, Status: "active", Capabilities: []string{}, RequiredProviderCapabilities: []string{}}
	version := &contracts.ModelVersion{ModelID: id, Version: "v1", R2Prefix: "v2/test/v1", Status: "ready", AggregateSHA256: strings.Repeat("a", 64), FileCount: 1,
		HuggingFaceArtifact: &contracts.HuggingFaceArtifact{RepoID: "EigenLabs/test", Revision: strings.Repeat("a", 40), PathPrefix: "mlx"}}
	files := []contracts.ModelVersionFile{{Path: "config.json", SHA256: strings.Repeat("b", 64), Role: "config"}}
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
	for _, record := range cached.ListActiveModelRegistry() {
		if record.ID == id && record.ActiveVersion.HuggingFaceArtifact != nil {
			t.Fatal("stale list source")
		}
	}
}
