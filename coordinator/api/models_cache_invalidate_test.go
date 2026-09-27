package api

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// An admin catalog mutation must be visible on the very next /v1/models and
// /v1/models/openrouter request, not after the 2s/5s TTLs: every admin alias
// and registry handler calls SyncModelCatalog, which drops the derived cache
// entries after publishing the updated routing catalog.
func TestCatalogSyncInvalidatesModelCaches(t *testing.T) {
	h := newCachedEndpointHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	const modelA, modelB = "invalidate-model-a", "invalidate-model-b"
	h.seedCatalogModel(t, modelA)
	h.connectProvider(t, ctx, modelA)

	status, first := h.get(t, ctx, "/v1/models", "test-key")
	mustOK(t, status, first)
	if ids := modelIDs(t, first); !containsID(ids, modelA) || containsID(ids, modelB) {
		t.Fatalf("initial list = %v, want only %s", ids, modelA)
	}
	status, feed := h.get(t, ctx, "/v1/models/openrouter", "test-key")
	mustOK(t, status, feed)
	if _, ok := h.srv.readCacheGet(openRouterFeedCacheKey); !ok {
		t.Fatal("openrouter feed should be cached after the first request")
	}

	// Catalog change inside the TTL, then the sync every admin mutation runs.
	h.seedCatalogModel(t, modelB)
	h.connectProvider(t, ctx, modelB)
	h.srv.SyncModelCatalog()

	if _, ok := h.srv.readCacheGet(openRouterFeedCacheKey); ok {
		t.Fatal("openrouter feed cache survived SyncModelCatalog")
	}
	status, fresh := h.get(t, ctx, "/v1/models", "test-key")
	mustOK(t, status, fresh)
	if ids := modelIDs(t, fresh); !containsID(ids, modelA) || !containsID(ids, modelB) {
		t.Fatalf("post-sync list = %v, want both models without waiting for the TTL", ids)
	}
}

// Capture one catalog read before blocking. SyncModelCatalog can proceed with
// its own read while the first request still holds a pre-mutation snapshot.
type blockedCatalogSnapshotStore struct {
	store.Store
	blocked atomic.Bool
	entered chan struct{}
	release chan struct{}
}

func (s *blockedCatalogSnapshotStore) ListActiveModelRegistryWithError() ([]store.ModelRegistryRecord, error) {
	rows, err := s.Store.ListActiveModelRegistryWithError()
	if s.blocked.CompareAndSwap(false, true) {
		close(s.entered)
		<-s.release
	}
	return rows, err
}

func TestCatalogSyncRejectsInflightCachePublication(t *testing.T) {
	for _, view := range []string{"entries", "list", "openrouter"} {
		t.Run(view, func(t *testing.T) {
			h := newCachedEndpointHarness(t)
			t.Cleanup(h.srv.Close)
			h.seedCatalogModel(t, "catalog-before-sync")
			st := &blockedCatalogSnapshotStore{
				Store: h.srv.store, entered: make(chan struct{}), release: make(chan struct{}),
			}
			h.srv.store = st
			var releaseOnce sync.Once
			release := func() { releaseOnce.Do(func() { close(st.release) }) }
			t.Cleanup(release)
			read := func() error {
				switch view {
				case "entries":
					_, err := h.srv.cachedModelEntries(false)
					return err
				case "list":
					_, err := h.srv.cachedModelListBody(false)
					return err
				default:
					rr := httptest.NewRecorder()
					h.srv.handleListModelsOpenRouter(rr, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
					if rr.Code != http.StatusOK {
						return fmt.Errorf("catalog status = %d, body = %s", rr.Code, rr.Body.String())
					}
					return nil
				}
			}
			done := make(chan error, 1)
			go func() { done <- read() }()
			select {
			case <-st.entered:
			case <-time.After(5 * time.Second):
				t.Fatal("catalog read did not start")
			}
			// This sync completes and evicts the catalog keys while the first
			// request still holds the old one-model snapshot.
			h.seedCatalogModel(t, "catalog-after-sync")
			release()
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			for _, key := range []string{modelEntriesCacheKey(false), modelListBodyCacheKey(false), openRouterFeedCacheKey} {
				if _, ok := h.srv.readCache.lookup(key); ok {
					t.Fatalf("pre-sync request repopulated %q after invalidation", key)
				}
			}
			if err := read(); err != nil {
				t.Fatal(err)
			}
			key := modelEntriesCacheKey(false)
			if view == "list" {
				key = modelListBodyCacheKey(false)
			} else if view == "openrouter" {
				key = openRouterFeedCacheKey
			}
			if _, ok := h.srv.readCache.lookup(key); !ok {
				t.Fatalf("post-sync request did not cache %q", key)
			}
		})
	}
}
