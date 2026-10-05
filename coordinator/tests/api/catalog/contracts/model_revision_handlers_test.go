package catalog_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/api"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestPublishModelRevisionPreservesMetadataAndApprovesTransition(t *testing.T) {
	manifest := validTestManifest()
	manifest.Version = "v2"
	manifest.R2Prefix = testModelPrefix(manifest.ModelID, manifest.Version)
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/manifest.json") {
			httpx.WriteJSON(w, http.StatusOK, manifest)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/config.json") && r.Method == http.MethodHead {
			w.Header().Set("Content-Length", "123")
			w.WriteHeader(http.StatusOK)
			return
		}
		http.NotFound(w, r)
	}))
	defer cdn.Close()
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdn.URL)
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	st := store.NewCached(memory.NewMemory(store.Config{}), store.DefaultCacheConfig())
	reg := registry.New(slog.Default())
	srv := api.NewServer(reg, st, api.ServerConfig{}, slog.Default())
	t.Cleanup(srv.Close)
	seedActiveModel(t, st, manifest.ModelID, "Existing display name")
	before, err := st.GetModelRegistryRecord(manifest.ModelID)
	if err != nil {
		t.Fatal(err)
	}
	before.RuntimeParameters = map[string]any{"temperature": 0.7}
	if err := st.UpsertModelRegistryEntry(&before.ModelRegistryEntry); err != nil {
		t.Fatal(err)
	}
	cacheReadPrice := int64(37)
	if err := st.SetModelPrice(store.ModelPrice{
		AccountID: "platform", Model: manifest.ModelID,
		InputPrice: 123, OutputPrice: 456, CacheReadPrice: &cacheReadPrice,
	}); err != nil {
		t.Fatal(err)
	}
	invoke := func(action, version string) *httptest.ResponseRecorder {
		payload, _ := json.Marshal(map[string]string{"version": version})
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+manifest.ModelID+"/"+action, bytes.NewReader(payload))
		req.Header.Set("Authorization", "Bearer publish-secret")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		return w
	}
	w := invoke("publish-revision", "v2")
	if w.Code != http.StatusOK {
		t.Fatalf("publish: %d %s", w.Code, w.Body.String())
	}
	after, err := st.GetModelRegistryRecord(manifest.ModelID)
	if err != nil {
		t.Fatal(err)
	}
	if after.ActiveVersion.Version != "v2" || after.DisplayName != before.DisplayName || after.RuntimeParameters["temperature"] != 0.7 {
		t.Fatalf("metadata changed: %+v", after)
	}
	price, ok := st.GetModelPrice("platform", manifest.ModelID)
	if !ok || price.InputPrice != 123 || price.OutputPrice != 456 || price.CacheReadPrice == nil || *price.CacheReadPrice != cacheReadPrice {
		t.Fatalf("revision publication changed pricing: %+v", price)
	}
	if len(after.ServingVersions) != 2 || !reg.CatalogAcceptsWeightHash(manifest.ModelID, before.ActiveVersion.AggregateSHA256) {
		t.Fatal("old serving revision was revoked during promotion")
	}
	if after.ActiveVersion.HuggingFaceArtifact != nil {
		t.Fatal("new revision inherited a stale HF mirror")
	}
	if w := invoke("retire-revision", "v2"); w.Code != http.StatusConflict {
		t.Fatalf("retired active revision: %d", w.Code)
	}
	if w := invoke("retire-revision", before.ActiveVersion.Version); w.Code != http.StatusOK {
		t.Fatalf("retire: %d %s", w.Code, w.Body.String())
	}
	if reg.CatalogAcceptsWeightHash(manifest.ModelID, before.ActiveVersion.AggregateSHA256) {
		t.Fatal("retired hash still accepted")
	}
}

type revisionCatalogFailureStore struct {
	store.Store
	fail atomic.Bool
}

func (s *revisionCatalogFailureStore) ListActiveModelRegistryWithError() ([]store.ModelRegistryRecord, error) {
	if s.fail.Load() {
		return nil, errors.New("catalog unavailable")
	}
	return s.Store.ListActiveModelRegistryWithError()
}

func TestRevisionRetirementDoesNotAcknowledgeFailedPolicyRefresh(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	base := memory.NewMemory(store.Config{})
	seedActiveModel(t, base, "revision-refresh-test", "Test model")
	original, err := base.GetModelRegistryRecord("revision-refresh-test")
	if err != nil {
		t.Fatal(err)
	}
	newer := *original.ActiveVersion
	newer.Version = "replacement"
	newer.R2Prefix += "-replacement"
	if err := base.SetExistingModelVersion(&newer, original.Files); err != nil {
		t.Fatal(err)
	}
	if err := base.PromoteModelVersion(newer.ModelID, newer.Version); err != nil {
		t.Fatal(err)
	}
	st := &revisionCatalogFailureStore{Store: base}
	srv := api.NewServer(registry.New(slog.Default()), st, api.ServerConfig{}, slog.Default())
	t.Cleanup(srv.Close)
	body, _ := json.Marshal(map[string]string{"version": original.ActiveVersion.Version})
	invoke := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+newer.ModelID+"/retire-revision", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer publish-secret")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		return w
	}
	st.fail.Store(true)
	if w := invoke(); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("failed refresh acknowledged: %d %s", w.Code, w.Body.String())
	}
	st.fail.Store(false)
	if w := invoke(); w.Code != http.StatusOK {
		t.Fatalf("idempotent retry failed: %d %s", w.Code, w.Body.String())
	}
}
