package provider_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// Model a successful commit that consumes the request's remaining deadline.
// Any subsequent storage call observes cancellation, but local fencing must
// still complete for both first-time and idempotent revocations.
type revocationDeadlineStore struct {
	*memory.MemoryStore
	cancel context.CancelFunc
}

func (s *revocationDeadlineStore) RevokeAppAttestKey(ctx context.Context, key, account, reason string) (bool, error) {
	changed, err := s.MemoryStore.RevokeAppAttestKey(ctx, key, account, reason)
	s.cancel()
	return changed, err
}

func (s *revocationDeadlineStore) GetAppAttestShadowKey(ctx context.Context, key string) (*store.AppAttestShadowKey, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return s.MemoryStore.GetAppAttestShadowKey(ctx, key)
}

func TestAppAttestAdminRevocationFencesAfterCommitConsumesDeadline(t *testing.T) {
	for _, alreadyRevoked := range []bool{false, true} {
		name := "new_revocation"
		if alreadyRevoked {
			name = "idempotent_revocation"
		}
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			memory := memory.NewMemory(store.Config{})
			s, p, _ := newAuthorizationFixtureWithStore(t, &revocationDeadlineStore{MemoryStore: memory, cancel: cancel})
			s.SetAdminKey("admin-secret")
			if _, err := memory.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: "credential", AccountID: "account"}); err != nil {
				t.Fatal(err)
			}
			if alreadyRevoked {
				if _, err := memory.RevokeAppAttestKey(context.Background(), "credential", "account", "operator_revoked"); err != nil {
					t.Fatal(err)
				}
			}
			r := httptest.NewRequest(http.MethodPost, "/v1/admin/app-attest/revoke", strings.NewReader(`{"key_id":"credential","account_id":"account","reason":"operator_revoked"}`)).WithContext(ctx)
			r.Header.Set("Authorization", "Bearer admin-secret")
			w := httptest.NewRecorder()
			s.Handler().ServeHTTP(w, r)
			if ctx.Err() != context.Canceled {
				t.Fatal("durable revocation did not consume the request deadline")
			}
			if w.Code != http.StatusOK {
				t.Fatalf("successful durable revocation returned %d: %s", w.Code, w.Body.String())
			}
			var result struct {
				Revoked bool `json:"revoked"`
				Changed bool `json:"changed"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
			if !result.Revoked || result.Changed == alreadyRevoked {
				t.Fatalf("incorrect revocation result: %+v", result)
			}
			if _, authorized := s.registry.ProviderServingAuthorization(p); authorized {
				t.Fatal("committed revocation left the local connection authorized")
			}
		})
	}
}
