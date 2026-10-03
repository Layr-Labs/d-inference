package access

import (
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type failingPublishingStore struct{ *memory.MemoryStore }

func (s *failingPublishingStore) FindPublishingAPIKeysWithError() ([]store.PublishingAPIKey, error) {
	return nil, errors.New("database unavailable")
}

func TestPublishingAPIKeyStoreErrorSurfacesButBootstrapStillWorks(t *testing.T) {
	st := &failingPublishingStore{MemoryStore: memory.NewMemory(store.Config{})}
	srv := New(st, slog.New(slog.DiscardHandler), 0, Hooks{})
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "")
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", nil)
	req.Header.Set("Authorization", "Bearer db-key")
	rec := httptest.NewRecorder()
	if _, ok := srv.RequirePublishingAPIKey(rec, req); ok {
		t.Fatal("expected DB-backed key lookup to fail")
	}
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("auth failure status = %d body = %s", rec.Code, rec.Body.String())
	}
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "bootstrap")
	req = httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", nil)
	req.Header.Set("Authorization", "Bearer bootstrap")
	rec = httptest.NewRecorder()
	if actor, ok := srv.RequirePublishingAPIKey(rec, req); !ok || actor.ID != "env-bootstrap" {
		t.Fatalf("expected bootstrap key to bypass DB, actor=%#v ok=%v", actor, ok)
	}
}
