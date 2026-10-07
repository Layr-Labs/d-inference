package catalog_test

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"
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
	reads := h.st.reads()
	status, cachedFeed := h.get(t, ctx, "/v1/models/openrouter", "test-key")
	mustOK(t, status, cachedFeed)
	if !bytes.Equal(feed, cachedFeed) || h.st.reads() != reads {
		t.Fatal("openrouter feed should be cached after the first request")
	}

	// Catalog change inside the TTL, then the sync every admin mutation runs.
	h.seedCatalogModel(t, modelB)
	h.connectProvider(t, ctx, modelB)
	h.srv.SyncModelCatalog()

	reads = h.st.reads()
	status, freshFeed := h.get(t, ctx, "/v1/models/openrouter", "test-key")
	mustOK(t, status, freshFeed)
	if h.st.reads() <= reads || !strings.Contains(string(freshFeed), modelB) {
		t.Fatal("openrouter feed cache survived SyncModelCatalog")
	}
	status, fresh := h.get(t, ctx, "/v1/models", "test-key")
	mustOK(t, status, fresh)
	if ids := modelIDs(t, fresh); !containsID(ids, modelA) || !containsID(ids, modelB) {
		t.Fatalf("post-sync list = %v, want both models without waiting for the TTL", ids)
	}
}
