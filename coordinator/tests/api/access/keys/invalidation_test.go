package keys_test

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	production "github.com/eigeninference/d-inference/coordinator/api/access/keys"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// The decorator observes the real store transition, and permits an auth request
// to refill the cache before the key mutation commits.
type mutationStore struct {
	*memory.MemoryStore
	authReads atomic.Int64
	before    func()
}

func (s *mutationStore) AuthenticateKey(token string) (*store.APIKey, error) {
	s.authReads.Add(1)
	return s.MemoryStore.AuthenticateKey(token)
}

func (s *mutationStore) UpdateAPIKey(account, id string, mutable store.APIKey) (*store.APIKey, error) {
	s.before()
	return s.MemoryStore.UpdateAPIKey(account, id, mutable)
}

func (s *mutationStore) RevokeAPIKeyByID(account, id string) error {
	s.before()
	return s.MemoryStore.RevokeAPIKeyByID(account, id)
}

func (s *mutationStore) RotateAPIKey(account, id string) (string, *store.APIKey, error) {
	s.before()
	return s.MemoryStore.RotateAPIKey(account, id)
}

func TestMutationsInvalidateBeforeAndAfterCommit(t *testing.T) {
	for _, operation := range []string{"update", "delete", "rotate"} {
		t.Run(operation, func(t *testing.T) {
			st := &mutationStore{MemoryStore: memory.NewMemory(store.Config{})}
			owner := access.New(st, slog.New(slog.NewTextHandler(io.Discard, nil)), 64*1024, access.Hooks{})
			h := production.New(st, owner)
			raw, key, err := st.CreateAPIKey("account", store.APIKeyCreate{})
			if err != nil {
				t.Fatal(err)
			}
			authenticate := func() int {
				r := httptest.NewRequest(http.MethodGet, "/", nil)
				r.Header.Set("Authorization", "Bearer "+raw)
				w := httptest.NewRecorder()
				owner.RequireAuth(func(http.ResponseWriter, *http.Request) {})(w, r)
				return w.Code
			}
			if authenticate() != http.StatusOK || authenticate() != http.StatusOK || st.authReads.Load() != 1 {
				t.Fatal("initial authentication was not cached")
			}
			st.before = func() {
				if authenticate() != http.StatusOK || st.authReads.Load() != 2 {
					t.Fatal("pre-mutation invalidation did not force a fresh read")
				}
			}
			r := httptest.NewRequest(http.MethodPatch, "/v1/keys/"+key.ID, strings.NewReader(`{"disabled":true}`))
			r.SetPathValue("id", key.ID)
			r = r.WithContext(context.WithValue(r.Context(), auth.CtxKeyUser, &store.User{AccountID: "account"}))
			w := httptest.NewRecorder()
			switch operation {
			case "update":
				h.HandleUpdateAPIKey(w, r)
			case "delete":
				h.HandleDeleteAPIKey(w, r)
			case "rotate":
				h.HandleRotateAPIKey(w, r)
			}
			if w.Code != http.StatusOK {
				t.Fatalf("mutation = %d: %s", w.Code, w.Body.String())
			}
			if authenticate() != http.StatusUnauthorized || st.authReads.Load() != 3 {
				t.Fatal("post-mutation invalidation retained the pre-commit auth result")
			}
		})
	}
}
