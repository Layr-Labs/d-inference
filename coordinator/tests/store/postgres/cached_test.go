package postgres_test

import (
	"sync"
	"time"

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

func (c *countingStore) count(name string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls[name]
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

func (f *fakeClock) advance(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
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
