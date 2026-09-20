package api

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func revisionPublishFixture(t *testing.T, backing store.Store) (*Server, *store.CachedStore, *store.ModelManifest) {
	t.Helper()
	manifest := validTestManifest()
	manifest.Version = "v2"
	manifest.R2Prefix = modelR2Prefix(manifest.ModelID, manifest.Version)
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/" + manifest.R2Prefix + "/manifest.json":
			writeJSON(w, http.StatusOK, manifest)
		case "/" + manifest.R2Prefix + "/config.json":
			w.Header().Set("Content-Length", "123")
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(cdn.Close)
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdn.URL)
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	cached := store.NewCached(backing, store.DefaultCacheConfig())
	seedActiveModel(t, cached, manifest.ModelID, "Existing model")
	srv := NewServer(registry.New(slog.Default()), cached, ServerConfig{}, slog.Default())
	t.Cleanup(srv.Close)
	return srv, cached, manifest
}

func publishRevisionRequest(t *testing.T, srv *Server, id string, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+id+"/publish-revision", bytes.NewReader(data))
	req.Header.Set("Authorization", "Bearer publish-secret")
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, req)
	return response
}

func TestPublishRevisionPinsOwnHFArtifactAndPublisher(t *testing.T) {
	sources := []*store.HuggingFaceArtifact{
		nil,
		{RepoID: "EigenLabs/new-weights", Revision: strings.Repeat("b", 40), PathPrefix: "mlx/q4"},
		{RepoID: "different-owner/another-repo", Revision: strings.Repeat("c", 40)},
	}
	for _, source := range sources {
		name := "r2-only"
		if source != nil {
			name = source.RepoID
		}
		t.Run(name, func(t *testing.T) {
			srv, st, manifest := revisionPublishFixture(t, store.NewMemory(store.Config{}))
			original, err := st.GetModelRegistryRecord(manifest.ModelID)
			if err != nil {
				t.Fatal(err)
			}
			oldSource := &store.HuggingFaceArtifact{RepoID: "EigenLabs/old-weights", Revision: strings.Repeat("a", 40)}
			original.ActiveVersion.HuggingFaceArtifact = oldSource
			if err := st.SetExistingModelVersion(original.ActiveVersion, original.Files); err != nil {
				t.Fatal(err)
			}
			body := map[string]any{"version": manifest.Version}
			if source != nil {
				body["hugging_face_artifact"] = source
			}
			response := publishRevisionRequest(t, srv, manifest.ModelID, body)
			if response.Code != http.StatusOK {
				t.Fatalf("publish: %d %s", response.Code, response.Body.String())
			}
			record, err := st.GetModelRegistryRecord(manifest.ModelID)
			if err != nil {
				t.Fatal(err)
			}
			if record.ActiveVersion.UploadedBy != "env-bootstrap" {
				t.Fatalf("publisher attribution lost: %q", record.ActiveVersion.UploadedBy)
			}
			if !reflect.DeepEqual(record.ActiveVersion.HuggingFaceArtifact, source) {
				t.Fatalf("wrong new source: %+v", record.ActiveVersion.HuggingFaceArtifact)
			}
			catalog := httptest.NewRecorder()
			srv.Handler().ServeHTTP(catalog, httptest.NewRequest(http.MethodGet, "/v1/models/catalog/"+manifest.ModelID, nil))
			var wire struct {
				HuggingFaceArtifact *store.HuggingFaceArtifact `json:"hugging_face_artifact"`
			}
			if err := json.Unmarshal(catalog.Body.Bytes(), &wire); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(wire.HuggingFaceArtifact, source) {
				t.Fatalf("provider catalog lost new source: %s", catalog.Body.String())
			}
			if err := st.PromoteModelVersion(manifest.ModelID, original.ActiveVersion.Version); err != nil {
				t.Fatal(err)
			}
			rollback, err := st.GetModelRegistryRecord(manifest.ModelID)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(rollback.ActiveVersion.HuggingFaceArtifact, oldSource) {
				t.Fatal("new source overwrote the old revision's rollback locator")
			}
		})
	}
}

func TestPublishRevisionRejectsInvalidHFSourceBeforePromotion(t *testing.T) {
	srv, st, manifest := revisionPublishFixture(t, store.NewMemory(store.Config{}))
	original, err := st.GetModelRegistryRecord(manifest.ModelID)
	if err != nil {
		t.Fatal(err)
	}
	for _, source := range []store.HuggingFaceArtifact{
		{RepoID: "EigenLabs/test", Revision: "main"},
		{RepoID: "https://other.test/repo", Revision: strings.Repeat("a", 40)},
		{RepoID: "EigenLabs/test", Revision: strings.Repeat("a", 40), PathPrefix: "../weights"},
	} {
		response := publishRevisionRequest(t, srv, manifest.ModelID, map[string]any{"version": manifest.Version, "hugging_face_artifact": source})
		if response.Code != http.StatusBadRequest {
			t.Fatalf("invalid source accepted: %d %s", response.Code, response.Body.String())
		}
	}
	record, err := st.GetModelRegistryRecord(manifest.ModelID)
	if err != nil || record.ActiveVersion.Version != original.ActiveVersion.Version {
		t.Fatal("invalid HF source changed desired revision", err)
	}
}

func TestPublishRevisionReturnsRetryableErrorUntilLivePolicyRefreshes(t *testing.T) {
	base := store.NewMemory(store.Config{})
	failing := &revisionCatalogFailureStore{Store: base}
	srv, _, manifest := revisionPublishFixture(t, failing)
	source := &store.HuggingFaceArtifact{RepoID: "EigenLabs/retry-weights", Revision: strings.Repeat("b", 40)}
	body := map[string]any{"version": manifest.Version, "hugging_face_artifact": source}
	failing.fail.Store(true)
	response := publishRevisionRequest(t, srv, manifest.ModelID, body)
	if response.Code != http.StatusServiceUnavailable || response.Header().Get("Retry-After") == "" {
		t.Fatalf("failed refresh was acknowledged: %d %s", response.Code, response.Body.String())
	}
	committed, err := base.GetModelRegistryRecord(manifest.ModelID)
	if err != nil || committed.ActiveVersion.Version != manifest.Version {
		t.Fatal("expected committed promotion awaiting refresh", err)
	}
	if srv.registry.CatalogWeightHash(manifest.ModelID) == manifest.AggregateSHA256 {
		t.Fatal("failure fixture did not preserve stale live policy")
	}
	failing.fail.Store(false)
	response = publishRevisionRequest(t, srv, manifest.ModelID, body)
	if response.Code != http.StatusOK {
		t.Fatalf("retry: %d %s", response.Code, response.Body.String())
	}
	if srv.registry.CatalogWeightHash(manifest.ModelID) != manifest.AggregateSHA256 {
		t.Fatal("successful retry did not refresh live policy")
	}
}
