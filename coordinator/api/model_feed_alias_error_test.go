package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type failedFeedAliasStore struct {
	*store.MemoryStore
	fail  atomic.Bool
	reads atomic.Int64
}

func (s *failedFeedAliasStore) ListModelAliases() ([]store.ModelAlias, error) {
	s.reads.Add(1)
	if s.fail.Load() {
		return nil, errors.New("alias inventory unavailable")
	}
	return s.MemoryStore.ListModelAliases()
}

func TestModelFeedAliasReadFailureIsNotCachedAsMissingAliases(t *testing.T) {
	const alias, retired = "public-model", "retired-build"
	for _, path := range []string{"/v1/models", "/v1/models?include_builds=1", "/v1/models/" + alias, "/v1/models/openrouter"} {
		t.Run(path, func(t *testing.T) {
			st := &failedFeedAliasStore{MemoryStore: store.NewMemory(store.Config{AdminKey: "test-key"})}
			for _, id := range []string{"desired-build", "previous-build", retired} {
				seedActiveModel(t, st, id, id)
			}
			if err := st.UpsertModelAlias(&store.ModelAlias{AliasID: alias, Active: true, DesiredBuild: "desired-build", PreviousBuild: "previous-build", RetiredBuilds: []string{retired}}); err != nil {
				t.Fatal(err)
			}
			logger := quietLogger()
			srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
			t.Cleanup(srv.Close)
			srv.SyncModelCatalog()
			ts := httptest.NewServer(srv.Handler())
			t.Cleanup(ts.Close)
			client := ts.Client()
			client.Timeout = 5 * time.Second
			get := func(wantStatus int) []string {
				t.Helper()
				req, err := http.NewRequest(http.MethodGet, ts.URL+path, nil)
				if err != nil {
					t.Fatal(err)
				}
				req.Header.Set("Authorization", "Bearer test-key")
				resp, err := client.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				defer resp.Body.Close()
				body, err := io.ReadAll(resp.Body)
				if err != nil {
					t.Fatal(err)
				}
				if resp.StatusCode != wantStatus {
					t.Fatalf("status = %d, want %d; body = %s", resp.StatusCode, wantStatus, body)
				}
				var result struct {
					ID   string                `json:"id"`
					Data []struct{ ID string } `json:"data"`
				}
				if err := json.Unmarshal(body, &result); err != nil {
					t.Fatal(err)
				}
				var ids []string
				if result.ID != "" {
					ids = append(ids, result.ID)
				}
				for _, entry := range result.Data {
					ids = append(ids, entry.ID)
				}
				return ids
			}
			st.reads.Store(0)
			st.fail.Store(true)
			get(http.StatusInternalServerError)
			st.fail.Store(false)
			ids := get(http.StatusOK)
			if !slices.Contains(ids, alias) {
				t.Fatalf("recovered catalog omitted alias: %v", ids)
			}
			if path != "/v1/models?include_builds=1" && slices.Contains(ids, retired) {
				t.Fatalf("recovered public catalog advertised retired build: %v", ids)
			}
			st.fail.Store(true)
			if cached := get(http.StatusOK); !slices.Equal(cached, ids) {
				t.Fatalf("cached catalog changed: %v, want %v", cached, ids)
			}
			if reads := st.reads.Load(); reads != 2 {
				t.Fatalf("alias reads = %d, want failed read + recovery", reads)
			}
		})
	}
}
