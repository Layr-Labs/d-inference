package access

import (
	"fmt"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func testOwner() (*Owner, *memory.MemoryStore) {
	st := memory.NewMemory(store.Config{AdminKey: "legacy-key"})
	return New(st, slog.New(slog.NewTextHandler(io.Discard, nil)), 64*1024, Hooks{}), st
}

func TestAPIKeyCacheExpiryGenerationAndEviction(t *testing.T) {
	s, _ := testOwner()
	now := time.Now()
	s.storeAPIKeyCache("expired", apiKeyCacheEntry{cachedAt: now.Add(-apiKeyCacheTTL - time.Second)})
	if _, ok := s.lookupAPIKeyCache("expired"); ok {
		t.Fatal("expired entry was accepted")
	}
	s.storeAPIKeyCache("negative", apiKeyCacheEntry{cachedAt: now})
	if entry, ok := s.lookupAPIKeyCache("negative"); !ok || entry.key != nil {
		t.Fatal("negative auth result was not cached")
	}
	s.InvalidateAllAPIKeyCache()
	if _, ok := s.lookupAPIKeyCache("negative"); ok {
		t.Fatal("generation invalidation retained an auth result")
	}
	s.apiKeyCache["stale"] = apiKeyCacheEntry{cachedAt: now, gen: s.apiKeyCacheGen - 1}
	if _, ok := s.lookupAPIKeyCache("stale"); ok {
		t.Fatal("old generation was accepted")
	}
	s.InvalidateAllAPIKeyCache()
	for i := range apiKeyCacheMaxSize + 1 {
		s.storeAPIKeyCache(fmt.Sprint(i), apiKeyCacheEntry{cachedAt: now.Add(time.Duration(i))})
	}
	if len(s.apiKeyCache) != apiKeyCacheMaxSize {
		t.Fatalf("cache size = %d", len(s.apiKeyCache))
	}
	if _, ok := s.lookupAPIKeyCache("0"); ok {
		t.Fatal("oldest entry was not evicted")
	}
	s.InvalidateAPIKeyCache("1")
	if _, ok := s.lookupAPIKeyCache("1"); ok {
		t.Fatal("single-key invalidation retained an auth result")
	}
}

func TestAPIKeyCacheConcurrentInvalidation(t *testing.T) {
	s, _ := testOwner()
	var wg sync.WaitGroup
	for worker := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range 100 {
				token := fmt.Sprintf("%d-%d", worker, i)
				s.storeAPIKeyCache(token, apiKeyCacheEntry{cachedAt: time.Now()})
				s.lookupAPIKeyCache(token)
				s.InvalidateAPIKeyCache(token)
				if i%10 == 0 {
					s.InvalidateAllAPIKeyCache()
				}
			}
		}()
	}
	wg.Wait()
	s.InvalidateAllAPIKeyCache()
	if len(s.apiKeyCache) != 0 {
		t.Fatal("invalidation did not clear the cache")
	}
}
