package api

import (
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A failed lookup can be transient: a following write may succeed. Keep the
// underlying store available so this test detects destructive fall-through.
type aliasReadErrorStore struct {
	store.Store
	aliasID  string
	recordID string
}

func (s *aliasReadErrorStore) GetModelAlias(id string) (*store.ModelAlias, bool, error) {
	if id == s.aliasID {
		return nil, false, errors.New("temporary alias read failure")
	}
	return s.Store.GetModelAlias(id)
}

func (s *aliasReadErrorStore) GetModelRegistryRecord(id string) (*store.ModelRegistryRecord, error) {
	if id == s.recordID {
		return nil, errors.New("temporary model read failure")
	}
	return s.Store.GetModelRegistryRecord(id)
}

func TestAliasUpsertReadFailurePreservesStoredState(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	for _, tc := range []struct {
		name, path, body, aliasID, recordID string
		openRouterOnly                      bool
	}{
		{"rollout history", "aliases", `{"alias_id":"public","desired_build":"next"}`, "public", "", false},
		{"OpenRouter ownership", "aliases", `{"alias_id":"public","desired_build":"next"}`, "public", "", true},
		{"standard namespace", "aliases", `{"alias_id":"concrete","desired_build":"next"}`, "", "concrete", false},
		{"OpenRouter namespace", "openrouter-aliases", `{"id":"concrete","source_model":"source","openrouter_slug":"vendor/model","hugging_face_id":"vendor/model"}`, "", "concrete", false},
		{"desired build", "aliases", `{"alias_id":"public","desired_build":"next"}`, "", "next", false},
		{"previous build", "aliases", `{"alias_id":"public","desired_build":"next","previous_build":"current"}`, "", "current", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			memory := store.NewMemory(store.Config{})
			for _, id := range []string{"next", "current", "retired", "concrete"} {
				seedActiveModel(t, memory, id, id)
			}
			for _, alias := range []*store.ModelAlias{
				{AliasID: "source", DesiredBuild: "current", Active: true},
				{AliasID: "public", DesiredBuild: "current", RetiredBuilds: []string{"retired"}, Active: true,
					OpenRouterOnly: tc.openRouterOnly, SourceModel: "source"},
			} {
				if err := memory.UpsertModelAlias(alias); err != nil {
					t.Fatal(err)
				}
			}
			before, err := memory.ListModelAliases()
			if err != nil {
				t.Fatal(err)
			}
			st := &aliasReadErrorStore{Store: memory, aliasID: tc.aliasID, recordID: tc.recordID}
			srv := NewServer(registry.New(slog.Default()), st, ServerConfig{}, slog.Default())
			req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+tc.path, strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer publish-secret")
			rec := httptest.NewRecorder()
			srv.Handler().ServeHTTP(rec, req)
			if rec.Code != http.StatusInternalServerError {
				t.Errorf("status = %d, want 500; body = %s", rec.Code, rec.Body.String())
			}
			after, err := memory.ListModelAliases()
			if err != nil || !reflect.DeepEqual(before, after) {
				t.Errorf("failed lookup changed aliases: before=%+v after=%+v err=%v", before, after, err)
			}
		})
	}
}

func TestRegisterModelAliasReadFailurePreservesNamespace(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	const id = "mlx-community/test"
	memory := store.NewMemory(store.Config{})
	seedActiveModel(t, memory, "current", "current")
	prior := &store.ModelAlias{AliasID: id, DesiredBuild: "current", Active: true}
	if err := memory.UpsertModelAlias(prior); err != nil {
		t.Fatal(err)
	}
	var fetches atomic.Int64
	prefix := modelR2Prefix(id, "v1")
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fetches.Add(1)
		switch r.URL.Path {
		case "/" + prefix + "/manifest.json":
			writeJSON(w, http.StatusOK, validTestManifest())
		case "/" + prefix + "/config.json":
			w.Header().Set("Content-Length", "123")
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer cdn.Close()
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdn.URL)
	srv := NewServer(registry.New(slog.Default()), &aliasReadErrorStore{Store: memory, aliasID: id}, ServerConfig{}, slog.Default())
	defer srv.Close()
	body := `{"model_id":"mlx-community/test","version":"v1","quantization":"4bit","max_context_length":32768,"max_output_length":8192,"min_ram_gb":16,"input_price":50000,"output_price":200000,"promote":true}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, req)
	if response.Code != http.StatusInternalServerError {
		t.Errorf("status=%d want500: %s", response.Code, response.Body.String())
	}
	if fetches.Load() != 0 {
		t.Errorf("namespace read failure fetched %d artifacts", fetches.Load())
	}
	if rec, err := memory.GetModelRegistryRecord(id); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("concrete record created after lookup failure: %+v err=%v", rec, err)
	}
	after, found, err := memory.GetModelAlias(id)
	if err != nil || !found || after.DesiredBuild != prior.DesiredBuild {
		t.Errorf("existing alias changed: %+v found=%v err=%v", after, found, err)
	}
}
