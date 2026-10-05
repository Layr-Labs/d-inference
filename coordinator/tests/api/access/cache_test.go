package access_test

import (
	"fmt"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/internal/api/access/authcache"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func testOwner() (*production.Owner, *memory.MemoryStore) {
	st := memory.NewMemory(store.Config{AdminKey: "legacy-key"})
	return production.New(st, slog.New(slog.NewTextHandler(io.Discard, nil)), 64*1024, production.Hooks{}), st
}

func TestAPIKeyCacheExpiryGenerationAndEviction(t *testing.T) {
	now := time.Now()
	s := authcache.New(func() time.Time { return now })
	_, generation, _ := s.Lookup("expired")
	s.Publish("expired", nil, generation)
	now = now.Add(authcache.TTL + time.Second)
	if _, _, ok := s.Lookup("expired"); ok {
		t.Fatal("expired entry was accepted")
	}
	s.Publish("negative", nil, generation)
	if key, _, ok := s.Lookup("negative"); !ok || key != nil {
		t.Fatal("negative auth result was not cached")
	}
	s.InvalidateAll()
	if _, _, ok := s.Lookup("negative"); ok {
		t.Fatal("generation invalidation retained an auth result")
	}
	if s.Publish("stale", nil, generation) {
		t.Fatal("old generation publication was accepted")
	}
	if _, _, ok := s.Lookup("stale"); ok {
		t.Fatal("old generation was accepted")
	}
	s.InvalidateAll()
	_, generation, _ = s.Lookup("0")
	for i := range authcache.MaxEntries + 1 {
		now = now.Add(time.Nanosecond)
		s.Publish(fmt.Sprint(i), nil, generation)
	}
	count := 0
	for i := range authcache.MaxEntries + 1 {
		if _, _, ok := s.Lookup(fmt.Sprint(i)); ok {
			count++
		}
	}
	if count != authcache.MaxEntries {
		t.Fatalf("cache size = %d", count)
	}
	if _, _, ok := s.Lookup("0"); ok {
		t.Fatal("oldest entry was not evicted")
	}
	s.Invalidate("1")
	if _, _, ok := s.Lookup("1"); ok {
		t.Fatal("single-key invalidation retained an auth result")
	}
}

func TestAPIKeyCacheConcurrentInvalidation(t *testing.T) {
	s := authcache.New(time.Now)
	var wg sync.WaitGroup
	for worker := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range 100 {
				token := fmt.Sprintf("%d-%d", worker, i)
				_, generation, _ := s.Lookup(token)
				s.Publish(token, nil, generation)
				s.Lookup(token)
				s.Invalidate(token)
				if i%10 == 0 {
					s.InvalidateAll()
				}
			}
		}()
	}
	wg.Wait()
	s.InvalidateAll()
	for worker := range 8 {
		for i := range 100 {
			if _, _, ok := s.Lookup(fmt.Sprintf("%d-%d", worker, i)); ok {
				t.Fatal("invalidation did not clear the cache")
			}
		}
	}
}
