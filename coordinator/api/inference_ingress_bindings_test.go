package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type ingressBindingStore struct {
	store.Store
	models atomic.Int64
	owners atomic.Int64
}

func (s *ingressBindingStore) GetModelRegistryRecord(model string) (*store.ModelRegistryRecord, error) {
	s.models.Add(1)
	return s.Store.GetModelRegistryRecord(model)
}

func (s *ingressBindingStore) ListProvidersByAccount(ctx context.Context, account string) ([]store.ProviderRecord, error) {
	s.owners.Add(1)
	return s.Store.ListProvidersByAccount(ctx, account)
}

// The mounted endpoints must keep current store and limiter bindings, while
// authentication and parsing precede quota admission and self-route preflight.
func TestInferenceIngressRoutesUseCurrentStoreAndTokenLimiters(t *testing.T) {
	for _, tc := range []struct {
		path string
		body string
	}{
		{"/v1/chat/completions", `{"model":"ingress-current","messages":[{"role":"user","content":"hello"}],"max_tokens":8}`},
		{"/v1/responses", `{"model":"ingress-current","input":"hello","max_output_tokens":8}`},
		{"/v1/completions", `{"model":"ingress-current","prompt":"hello","max_tokens":8}`},
		{"/v1/messages", `{"model":"ingress-current","messages":[{"role":"user","content":"hello"}],"max_tokens":8}`},
	} {
		t.Run(tc.path, func(t *testing.T) {
			srv, original := newKeyTestServer(t)
			t.Cleanup(srv.Close)
			handler := srv.Handler()
			replacement := store.NewMemory(store.Config{})
			seedActiveModel(t, replacement, "ingress-current", "Current ingress model")
			key, err := replacement.CreateKeyForAccount("ingress-owner")
			if err != nil {
				t.Fatal(err)
			}
			seedProviderRecord(t, replacement, "offline-session", "ingress-serial", "ingress-owner")
			current := &ingressBindingStore{Store: replacement}
			srv.store = current
			srv.SyncModelCatalog()
			limiter := ratelimit.NewTokenLimiter(1000, 1_000_000, 0.001, 1)
			if ok, _, _ := limiter.Allow("ingress-owner", 0, 1); !ok {
				t.Fatal("new limiter must admit the operation that exhausts its output bucket")
			}
			srv.SetTokenLimiters(limiter, nil)
			request := func(body, credential string, want int) *httptest.ResponseRecorder {
				t.Helper()
				r := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(body))
				r.Header.Set("X-Darkbloom-Route", "self")
				if credential != "" {
					r.Header.Set("Authorization", "Bearer "+credential)
				}
				w := httptest.NewRecorder()
				handler.ServeHTTP(w, r)
				if w.Code != want {
					t.Fatalf("status=%d want=%d body=%s", w.Code, want, w.Body.String())
				}
				return w
			}

			request("invalid JSON", "", http.StatusUnauthorized)
			request("invalid JSON", key, http.StatusBadRequest)
			if current.models.Load() != 0 || current.owners.Load() != 0 {
				t.Fatal("authentication or JSON rejection reached model/owner reads")
			}
			limited := request(tc.body, key, http.StatusTooManyRequests)
			if !strings.Contains(limited.Body.String(), "output_tokens") || limited.Header().Get("Retry-After") == "" {
				t.Fatalf("current limiter did not reject output admission: %s", limited.Body.String())
			}
			if current.models.Load() == 0 || current.owners.Load() != 0 {
				t.Fatal("quota admission lost current model reads or reached self-route preflight")
			}

			srv.SetTokenLimiters(nil, nil)
			offline := request(tc.body, key, http.StatusServiceUnavailable)
			if !strings.Contains(offline.Body.String(), `"machine_offline"`) || offline.Header().Get("Retry-After") != "30" {
				t.Fatalf("self-route ignored current persisted ownership: %s", offline.Body.String())
			}
			if current.owners.Load() == 0 {
				t.Fatal("self-route used the replaced store")
			}
			if providers, err := original.ListProvidersByAccount(context.Background(), "ingress-owner"); err != nil || len(providers) != 0 {
				t.Fatalf("test must distinguish the original empty store: %v %v", providers, err)
			}
		})
	}
}
