package api

import (
	"context"
	"testing"
	"time"
)

// An admin catalog mutation must be visible on the very next /v1/models and
// /v1/models/openrouter request, not after the 2s/5s TTLs: every admin alias
// and registry handler calls SyncModelCatalog, which drops the derived cache
// entries first.
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
