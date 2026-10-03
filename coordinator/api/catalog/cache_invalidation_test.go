package catalog

import (
	"bytes"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestCatalogInvalidationPreservesOtherDomains(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	cache := readcache.New()
	srv := New(registry.New(logger), memory.NewMemory(store.Config{}), nil, cache, logger, Hooks{})
	stats := []byte(`{"total_requests":1}`)
	cache.Set("stats:v1", stats, time.Hour)
	cache.Set(openRouterFeedCacheKey, []byte(`{"data":[]}`), time.Hour)
	if _, ok := cache.Get(openRouterFeedCacheKey); !ok {
		t.Fatal("openrouter feed should be cached before invalidation")
	}
	srv.InvalidateCatalogCache()
	if _, ok := cache.Get(openRouterFeedCacheKey); ok {
		t.Fatal("openrouter feed cache survived catalog invalidation")
	}
	if cached, ok := cache.Get("stats:v1"); !ok || !bytes.Equal(cached, stats) {
		t.Fatal("catalog invalidation evicted shared stats entry")
	}
}
