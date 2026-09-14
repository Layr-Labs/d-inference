package catalog

import (
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestPublishingAPIKeyStoreErrorSurfacesButBootstrapStillWorks(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := &failingModelRegistryStore{MemoryStore: store.NewMemory(store.Config{}), keyErr: errors.New("database unavailable")}
	srv := newTestController(registry.New(logger), st, logger)

	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "")
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", nil)
	req.Header.Set("Authorization", "Bearer db-key")
	rec := httptest.NewRecorder()
	if _, ok := srv.requirePublishingAPIKey(rec, req); ok {
		t.Fatal("expected DB-backed key lookup to fail")
	}
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("auth failure status = %d body = %s", rec.Code, rec.Body.String())
	}

	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "bootstrap")
	req = httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", nil)
	req.Header.Set("Authorization", "Bearer bootstrap")
	rec = httptest.NewRecorder()
	if actor, ok := srv.requirePublishingAPIKey(rec, req); !ok || actor.ID != "env-bootstrap" {
		t.Fatalf("expected bootstrap key to bypass DB, actor=%#v ok=%v", actor, ok)
	}
}
