package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// Cancel undoes the confirm: the API keys and provider tokens that the
// confirm revoked work again. Credentials revoked before the erasure stay
// revoked, and are listed again as before.
func TestErasureCancelRestoresOnlyCredentialsItRevoked(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			oldKey, oldRecord, err := s.CreateAPIKey(a.AccountID, store.APIKeyCreate{Name: "old key"})
			if err != nil {
				t.Fatal(err)
			}
			if !s.RevokeKey(oldKey) {
				t.Fatal("revoke the old key")
			}
			oldToken := erasurefixture.UniqueID("ptok-old")
			if err := s.CreateProviderToken(&store.ProviderToken{TokenHash: store.HashKey(oldToken), AccountID: a.AccountID, Label: "old mac", Active: true}); err != nil {
				t.Fatal(err)
			}
			if err := s.RevokeProviderToken(oldToken); err != nil {
				t.Fatal(err)
			}

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
			listed := map[string]bool{}
			for _, k := range keys {
				listed[k.ID] = !k.Disabled
			}
			if active, ok := listed[oldRecord.ID]; len(keys) != 2 || !ok || active {
				t.Fatalf("keys after cancel = %+v; want both, the old one disabled", keys)
			}
		})
	}
}
