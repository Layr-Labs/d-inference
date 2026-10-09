package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// revokedCredentials creates an API key and a provider token of a and
// revokes both. It returns the raw key and the raw token.
func revokedCredentials(t *testing.T, s store.Store, a erasurefixture.Account) (string, string) {
	t.Helper()
	key, _, err := s.CreateAPIKey(a.AccountID, store.APIKeyCreate{Name: "old key"})
	if err != nil {
		t.Fatal(err)
	}
	if !s.RevokeKey(key) {
		t.Fatal("revoke the old key")
	}
	token := erasurefixture.UniqueID("ptok-old")
	if err := s.CreateProviderToken(&store.ProviderToken{TokenHash: store.HashKey(token), AccountID: a.AccountID, Label: "old mac", Active: true}); err != nil {
		t.Fatal(err)
	}
	if err := s.RevokeProviderToken(token); err != nil {
		t.Fatal(err)
	}
	return key, token
}

// Cancel undoes the confirm: the API keys and provider tokens that the
// confirm changed from live to revoked work again. Credentials revoked before
// the erasure stay revoked and stay hidden, as the confirm left them.
func TestErasureCancelRestoresOnlyCredentialsItRevoked(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			oldKey, oldToken := revokedCredentials(t, s, a)

			now := time.Now().UTC()
			erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
			if _, err := s.AuthenticateKey(a.RawKey); err == nil {
				t.Fatal("API key authenticates while the erasure is pending")
			}
			if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", now.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}

			if _, err := s.AuthenticateKey(a.RawKey); err != nil {
				t.Fatalf("API key revoked by the erasure, after cancel: %v", err)
			}
			if _, err := s.GetProviderToken(a.ProviderToken); err != nil {
				t.Fatalf("provider token revoked by the erasure, after cancel: %v", err)
			}
			if k, err := s.AuthenticateKey(oldKey); err == nil {
				t.Fatalf("API key revoked before the erasure authenticates after cancel: %+v", k)
			}
			if pt, err := s.GetProviderToken(oldToken); err == nil {
				t.Fatalf("provider token revoked before the erasure is valid after cancel: %+v", pt)
			}
			keys, err := s.ListAPIKeys(a.AccountID)
			if err != nil {
				t.Fatal(err)
			}
			if len(keys) != 1 || keys[0].Disabled || keys[0].Name != "laptop key" {
				t.Fatalf("keys after cancel = %+v; want only the key that was live at confirm", keys)
			}
		})
	}
}

// A credential that is revoked during the grace period, for example because
// it leaked, stays revoked when the erasure is canceled. A credential that
// nothing revoked after the confirm is restored.
func TestErasureCancelKeepsCredentialsRevokedDuringGrace(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			otherKey, _, err := s.CreateAPIKey(a.AccountID, store.APIKeyCreate{Name: "second key"})
			if err != nil {
				t.Fatal(err)
			}
			otherToken := erasurefixture.UniqueID("ptok-second")
			if err := s.CreateProviderToken(&store.ProviderToken{TokenHash: store.HashKey(otherToken), AccountID: a.AccountID, Label: "second mac", Active: true}); err != nil {
				t.Fatal(err)
			}

			now := time.Now().UTC()
			erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
			if !s.RevokeKey(a.RawKey) {
				t.Fatal("revoking a key that the pending erasure would restore reports no change")
			}
			if err := s.RevokeProviderToken(a.ProviderToken); err != nil {
				t.Fatal(err)
			}
			if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", now.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}

			if k, err := s.AuthenticateKey(a.RawKey); err == nil {
				t.Fatalf("API key revoked during the grace period authenticates after cancel: %+v", k)
			}
			if pt, err := s.GetProviderToken(a.ProviderToken); err == nil {
				t.Fatalf("provider token revoked during the grace period is valid after cancel: %+v", pt)
			}
			if _, err := s.AuthenticateKey(otherKey); err != nil {
				t.Fatalf("API key that only the erasure revoked, after cancel: %v", err)
			}
			if _, err := s.GetProviderToken(otherToken); err != nil {
				t.Fatalf("provider token that only the erasure revoked, after cancel: %v", err)
			}
		})
	}
}
