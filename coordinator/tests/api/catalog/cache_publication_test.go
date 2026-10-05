package catalog_test

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

	production "github.com/eigeninference/d-inference/coordinator/api/catalog"
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
	production.Store
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
			cache := readcache.New()
			st := &blockedCatalogSnapshotStore{Store: st0, entered: make(chan struct{}), release: make(chan struct{})}
			st.blocked.Store(true)
			srv := production.New(registry.New(logger), st, nil, cache, logger, production.Hooks{})
			seed := func(t *testing.T, model string) { seedActiveModel(t, st0, model, model); srv.SyncModelCatalog() }
			seed(t, "catalog-before-sync")
			st.blocked.Store(false)
			var releaseOnce sync.Once
			release := func() { releaseOnce.Do(func() { close(st.release) }) }
			t.Cleanup(release)
			read := func() error {
				rr := httptest.NewRecorder()
				switch view {
				case "entries":
					req := httptest.NewRequest(http.MethodGet, "/v1/models/catalog-before-sync", nil)
					req.SetPathValue("id", "catalog-before-sync")
					srv.HandleGetModel(rr, req)
				case "list":
					srv.HandleListModels(rr, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
				default:
					srv.HandleListModelsOpenRouter(rr, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
				}
				if rr.Code != http.StatusOK && !(view == "entries" && rr.Code == http.StatusNotFound) {
					return fmt.Errorf("catalog status = %d, body = %s", rr.Code, rr.Body.String())
				}
				return nil
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
			for _, key := range []string{"models:entries:v1:include_builds=false", "models:entries:v1:include_builds=true", "models:list:v1:include_builds=false", "models:openrouter:v1"} {
				_, valueOK := cache.GetValue(key)
				if _, ok := cache.Get(key); ok || valueOK {
					t.Fatalf("pre-sync request repopulated %q after invalidation", key)
				}
			}
			if err := read(); err != nil {
				t.Fatal(err)
			}
			key := "models:entries:v1:include_builds=true"
			if view == "list" {
				key = "models:list:v1:include_builds=false"
			} else if view == "openrouter" {
				key = "models:openrouter:v1"
			}
			_, valueOK := cache.GetValue(key)
			if _, ok := cache.Get(key); !ok && !valueOK {
				t.Fatalf("post-sync request did not cache %q", key)
			}
		})
	}
}
