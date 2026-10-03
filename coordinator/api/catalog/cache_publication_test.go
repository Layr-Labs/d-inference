package catalog

import (
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// An admin catalog mutation must be visible on the very next /v1/models and
// /v1/models/openrouter request, not after the 2s/5s TTLs: every admin alias
// and registry handler calls SyncModelCatalog, which drops the derived cache
// entries after publishing the updated routing catalog.
// Capture one catalog read before blocking. SyncModelCatalog can proceed with
// its own read while the first request still holds a pre-mutation snapshot.
type blockedCatalogSnapshotStore struct {
	Store
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
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			st0 := memory.NewMemory(store.Config{})
			srv := New(registry.New(logger), st0, nil, readcache.New(), logger, Hooks{})
			seed := func(t *testing.T, model string) { seedActiveModel(t, st0, model, model); srv.SyncModelCatalog() }
			seed(t, "catalog-before-sync")
			st := &blockedCatalogSnapshotStore{
				Store: srv.store, entered: make(chan struct{}), release: make(chan struct{}),
			}
			srv.store = st
			var releaseOnce sync.Once
			release := func() { releaseOnce.Do(func() { close(st.release) }) }
			t.Cleanup(release)
			read := func() error {
				switch view {
				case "entries":
					_, err := srv.cachedModelEntries(false)
					return err
				case "list":
					_, err := srv.cachedModelListBody(false)
					return err
				default:
					rr := httptest.NewRecorder()
					srv.HandleListModelsOpenRouter(rr, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
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
			seed(t, "catalog-after-sync")
			release()
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			for _, key := range []string{modelEntriesCacheKey(false), modelListBodyCacheKey(false), openRouterFeedCacheKey} {
				_, valueOK := srv.readCache.GetValue(key)
				if _, ok := srv.readCache.Get(key); ok || valueOK {
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
			_, valueOK := srv.readCache.GetValue(key)
			if _, ok := srv.readCache.Get(key); !ok && !valueOK {
				t.Fatalf("post-sync request did not cache %q", key)
			}
		})
	}
}
