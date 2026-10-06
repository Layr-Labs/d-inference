package api_test

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type runtimeManifestFixture struct {
	*production.Server
	registry  *registry.Registry
	readCache *readcache.Cache
}

func runtimeManifestTestServer(t *testing.T) (*runtimeManifestFixture, *memory.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	cache := readcache.New()
	srv := production.NewRuntime(production.RuntimeDependencies{
		Registry: reg, Store: st, Ledger: payments.NewLedger(st), ReadCache: cache, Logger: logger,
	}, production.ServerConfig{}).Server
	t.Cleanup(srv.Close)
	return &runtimeManifestFixture{Server: srv, registry: reg, readCache: cache}, st
}

func runtimeManifestState(t *testing.T, srv *runtimeManifestFixture) (bool, *releases.RuntimeManifest) {
	t.Helper()
	// These assertions inspect current publication, independently of response TTL.
	srv.readCache.Invalidate("runtime_manifest:v1")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/runtime/manifest", nil))
	var body struct {
		Configured     bool                `json:"configured"`
		TemplateHashes map[string][]string `json:"template_hashes"`
	}
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &body) != nil {
		t.Fatalf("invalid runtime manifest: %d %s", w.Code, w.Body.String())
	}
	manifest := releases.NewRuntimeManifest()
	for name, hashes := range body.TemplateHashes {
		accepted := make(map[string]bool, len(hashes))
		for _, hash := range hashes {
			accepted[hash] = true
		}
		manifest.TemplateHashes[name] = accepted
	}
	return body.Configured, manifest
}
