package memory_test

import (
	"fmt"
	"sync"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/store/memory"

	shared "github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// countingStore forwards every call to a real Store and counts the inner
// reads of the lookups CachedStore caches. It is not a mock of behavior: the
// wrapped store answers every call. failWith and afterLoad exist so tests can
// exercise the transient-error and read/write-race paths deterministically.
type countingStore struct {
	store.Store
	mu        sync.Mutex
	calls     map[string]int
	failWith  error  // when set, cached lookups return it instead of forwarding
	afterLoad func() // runs after the inner read, before returning (race test)
}

func newCountingStore(inner store.Store) *countingStore {
	return &countingStore{Store: inner, calls: map[string]int{}}
}

func (c *countingStore) note(name string) {
	c.mu.Lock()
	c.calls[name]++
	c.mu.Unlock()
}

func (c *countingStore) GetUserByAccountID(accountID string) (*store.User, error) {
	c.note("GetUserByAccountID")
	if c.failWith != nil {
		return nil, c.failWith
	}
	u, err := c.Store.GetUserByAccountID(accountID)
	if c.afterLoad != nil {
		c.afterLoad()
	}
	return u, err
}

func (c *countingStore) GetUserByPrivyID(privyUserID string) (*store.User, error) {
	c.note("GetUserByPrivyID")
	if c.failWith != nil {
		return nil, c.failWith
	}
	return c.Store.GetUserByPrivyID(privyUserID)
}

func (c *countingStore) GetModelRegistryRecord(modelID string) (*store.ModelRegistryRecord, error) {
	c.note("GetModelRegistryRecord")
	if c.failWith != nil {
		return nil, c.failWith
	}
	rec, err := c.Store.GetModelRegistryRecord(modelID)
	if c.afterLoad != nil {
		c.afterLoad()
	}
	return rec, err
}

func (c *countingStore) GetModelManifest(modelID string) (*store.ModelManifest, error) {
	c.note("GetModelManifest")
	return c.Store.GetModelManifest(modelID)
}

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{t: time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)}
}

func (f *fakeClock) now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.t
}

// newCachedMemoryStore composes CachedStore -> countingStore -> MemoryStore
// with a fake clock and the production TTLs.
func newCachedMemoryStore(t *testing.T) (*store.CachedStore, *countingStore, *fakeClock) {
	t.Helper()
	clock := newFakeClock()
	counting := newCountingStore(production.NewMemory(store.Config{}))
	cfg := store.DefaultCacheConfig()
	cfg.Now = clock.now
	return store.NewCached(counting, cfg), counting, clock
}

const cachedTestHash = "0000000000000000000000000000000000000000000000000000000000000000"

func registryFixture(modelID, version string) (*store.ModelRegistryEntry, *store.ModelVersion, []store.ModelVersionFile) {
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "Model " + modelID, Status: "active", MinRAMGB: 16,
		MaxContextLength: 32768, MaxOutputLength: 8192,
		Capabilities:                 []string{"chat"},
		RequiredProviderCapabilities: []string{},
		RuntimeParameters:            map[string]any{"reasoning_parser": "qwen3", "nested": map[string]any{"k": []any{"a", "b"}}},
		Metadata:                     map[string]any{"hugging_face_id": "org/" + modelID},
	}
	v := &store.ModelVersion{ModelID: modelID, Version: version, R2Prefix: modelID + "/" + version,
		AggregateSHA256: cachedTestHash, TotalSizeBytes: 3, FileCount: 1, Status: "ready"}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 3, SHA256: cachedTestHash, Role: "config"}}
	return entry, v, files
}

// seedActiveModel registers and promotes one ready version so the model has
// an active registry record.
func seedActiveModel(t *testing.T, st store.Store, modelID, version string) {
	t.Helper()
	entry, v, files := registryFixture(modelID, version)
	if err := st.SetModelVersion(entry, v, files); err != nil {
		t.Fatalf("SetModelVersion(%s %s): %v", modelID, version, err)
	}
	if err := st.PromoteModelVersion(modelID, version); err != nil {
		t.Fatalf("PromoteModelVersion(%s %s): %v", modelID, version, err)
	}
}

func TestCachedStoreReturnsRecordCopies(t *testing.T) {
	cached, _, _ := newCachedMemoryStore(t)
	seedActiveModel(t, cached, "org/m1", "v1")

	r1, err := cached.GetModelRegistryRecord("org/m1")
	if err != nil {
		t.Fatal(err)
	}
	// Exactly what api/model_registry_handlers.go does before an upsert, plus
	// every other reference-typed field.
	r1.RuntimeParameters["reasoning_parser"] = "tampered"
	r1.RuntimeParameters["nested"].(map[string]any)["k"].([]any)[0] = "tampered"
	r1.Metadata["hugging_face_id"] = "tampered"
	r1.Capabilities[0] = "tampered"
	r1.Files[0].Path = "tampered"
	r1.ActiveVersion.Version = "tampered"
	r1.DisplayName = "tampered"

	r2, err := cached.GetModelRegistryRecord("org/m1")
	if err != nil {
		t.Fatal(err)
	}
	if r1 == r2 || r1.ActiveVersion == r2.ActiveVersion {
		t.Fatal("cache handed out the same pointer twice")
	}
	if r2.RuntimeParameters["reasoning_parser"] != "qwen3" ||
		r2.RuntimeParameters["nested"].(map[string]any)["k"].([]any)[0] != "a" ||
		r2.Metadata["hugging_face_id"] != "org/org/m1" ||
		r2.Capabilities[0] != "chat" ||
		r2.Files[0].Path != "config.json" ||
		r2.ActiveVersion.Version != "v1" ||
		r2.DisplayName != "Model org/m1" {
		t.Fatalf("caller mutation leaked into cache: %+v", r2)
	}

	// The structural clone must agree with the package's JSON-round-trip
	// clone (the existing oracle) on the same JSON-shaped data.
	oracle := shared.CloneModelRegistryEntry(&r2.ModelRegistryEntry)
	if fmt.Sprint(oracle.RuntimeParameters) != fmt.Sprint(r2.RuntimeParameters) ||
		fmt.Sprint(oracle.Metadata) != fmt.Sprint(r2.Metadata) {
		t.Fatalf("structural clone diverges from JSON clone:\n%v\n%v", oracle.RuntimeParameters, r2.RuntimeParameters)
	}
}
