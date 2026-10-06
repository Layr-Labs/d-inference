package access_test

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func authenticate(s *production.Owner, token string, next http.HandlerFunc) int {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	s.RequireAuth(next)(w, r)
	return w.Code
}

func TestAuthenticationPrincipalAndObservation(t *testing.T) {
	_, st := testOwner()
	user := &store.User{AccountID: "acct", PrivyUserID: "did:privy:test", Email: "test@example.com"}
	if err := st.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	cap := int64(123)
	raw, key, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{LimitMicroUSD: &cap, LimitReset: store.KeyResetDaily})
	if err != nil {
		t.Fatal(err)
	}
	var stages, kinds []string
	s := production.New(st, slog.New(slog.NewTextHandler(io.Discard, nil)), 64*1024, production.Hooks{
		SetOutcomeStage: func(_ *http.Request, stage string) { stages = append(stages, stage) },
		StampAuth: func(_ *http.Request, kind string, dbRead bool) {
			kinds = append(kinds, kind)
			if !dbRead {
				t.Error("linked identity requires a user read even on cache hits")
			}
		},
	})
	for range 2 {
		if code := authenticate(s, raw, func(w http.ResponseWriter, r *http.Request) {
			ctx := r.Context()
			if production.ConsumerKeyFromContext(ctx) != user.AccountID || production.KeyIDFromContext(ctx) != key.ID || auth.UserFromContext(ctx).AccountID != user.AccountID {
				t.Error("linked principal metadata changed")
			}
			if limit := production.KeyLimitMicroFromContext(ctx); limit == nil || *limit != cap || production.KeyLimitResetFromContext(ctx) != store.KeyResetDaily {
				t.Error("key spend metadata was not preserved")
			}
		}); code != http.StatusOK {
			t.Fatalf("authentication status = %d", code)
		}
	}
	if len(stages) != 2 || stages[0] != "auth" || len(kinds) != 2 || kinds[0] != "apikey_db" || kinds[1] != "apikey_cache" {
		t.Fatalf("observation stages=%v kinds=%v", stages, kinds)
	}
}

func TestProviderTokenRemainsUncachedAndRevocable(t *testing.T) {
	s, st := testOwner()
	token := "provider-token"
	digest := sha256.Sum256([]byte(token))
	if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: hex.EncodeToString(digest[:]), AccountID: "provider-owner", Active: true}); err != nil {
		t.Fatal(err)
	}
	if code := authenticate(s, token, func(w http.ResponseWriter, r *http.Request) {
		if production.ConsumerKeyFromContext(r.Context()) != "provider-owner" || production.KeyIDFromContext(r.Context()) != "" || production.APIKeyFromContext(r.Context()) == nil {
			t.Error("provider identity changed")
		}
	}); code != http.StatusOK {
		t.Fatalf("provider auth = %d", code)
	}
	if err := st.RevokeProviderToken(token); err != nil {
		t.Fatal(err)
	}
	if code := authenticate(s, token, func(http.ResponseWriter, *http.Request) { t.Error("revoked token accepted") }); code != http.StatusUnauthorized {
		t.Fatalf("revoked token auth = %d", code)
	}
}

func TestCacheHitRechecksKeyExpiryAndDisable(t *testing.T) {
	for _, disabled := range []bool{false, true} {
		_, st := testOwner()
		past := time.Now().Add(-time.Second)
		key := &store.APIKey{OwnerAccountID: "owner"}
		lookup := &credentialStore{Store: st, key: key}
		s := production.New(lookup, slog.New(slog.NewTextHandler(io.Discard, nil)), 64*1024, production.Hooks{})
		if code := authenticate(s, "cached-key", func(http.ResponseWriter, *http.Request) {}); code != http.StatusOK {
			t.Fatalf("initial key auth = %d", code)
		}
		key.Disabled = disabled
		if !disabled {
			key.ExpiresAt = &past
		}
		if code := authenticate(s, "cached-key", func(http.ResponseWriter, *http.Request) { t.Error("unusable key accepted") }); code != http.StatusUnauthorized {
			t.Fatalf("unusable cached key auth = %d", code)
		}
		if lookup.reads != 1 {
			t.Fatalf("cache hit performed %d store reads", lookup.reads)
		}
	}
}

type credentialStore struct {
	production.Store
	key   *store.APIKey
	reads int
}

func (s *credentialStore) AuthenticateKey(string) (*store.APIKey, error) {
	s.reads++
	return s.key, nil
}

func TestLegacyAndAdminIdentityRemainDistinct(t *testing.T) {
	s, _ := testOwner()
	s.SetAdminKey("admin-key")
	for _, tc := range []struct {
		token, account string
		metadata       bool
	}{
		{"legacy-key", store.LegacyAccountID("legacy-key"), true},
		{"admin-key", "admin", false},
	} {
		if code := authenticate(s, tc.token, func(w http.ResponseWriter, r *http.Request) {
			if production.ConsumerKeyFromContext(r.Context()) != tc.account || (production.APIKeyFromContext(r.Context()) != nil) != tc.metadata {
				t.Errorf("unexpected principal for %s", tc.account)
			}
		}); code != http.StatusOK {
			t.Fatalf("auth = %d", code)
		}
	}
}
