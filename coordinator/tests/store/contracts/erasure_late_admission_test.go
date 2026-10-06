package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// A request can pass HTTP authentication before account deletion starts and
// reach persistence afterward. Account-owned credentials and provider cards
// must therefore enforce the deletion boundary inside each store operation.
func TestErasureBlocksLateAccountAdmissions(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			for _, state := range []store.ErasureState{store.ErasurePending, store.ErasureErased, store.ErasureCanceled} {
				t.Run(string(state), func(t *testing.T) {
					ctx := context.Background()
					now := time.Now().UTC()
					a := erasurefixture.SeedAccount(t, s)
					req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
					switch state {
					case store.ErasureErased:
						if _, err := s.ScrubAccount(ctx, req.ID, now.Add(2*time.Hour)); err != nil {
							t.Fatal(err)
						}
					case store.ErasureCanceled:
						if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin", now.Add(time.Minute)); err != nil {
							t.Fatal(err)
						}
					}
					blocked := state != store.ErasureCanceled

					t.Run("api_key", func(t *testing.T) {
						raw, key, err := s.CreateAPIKey(a.AccountID, store.APIKeyCreate{Name: "late laptop key"})
						if blocked {
							if err == nil || raw != "" || key != nil {
								t.Errorf("CreateAPIKey after %s = key %v, raw present %t, error %v; want refusal", state, key, raw != "", err)
							}
							if keys, err := s.ListAPIKeys(a.AccountID); err != nil || len(keys) != 0 {
								t.Errorf("ListAPIKeys after refused creation = %v, %v; want no live keys", keys, err)
							}
							return
						}
						if err != nil {
							t.Fatal(err)
						}
						if got, err := s.AuthenticateKey(raw); err != nil || got.OwnerAccountID != a.AccountID {
							t.Fatalf("new key after cancel = %v, %v", got, err)
						}
					})

					t.Run("provider_token", func(t *testing.T) {
						raw := erasurefixture.UniqueID("late-provider-token")
						err := s.CreateProviderToken(&store.ProviderToken{
							TokenHash: store.HashKey(raw), AccountID: a.AccountID,
							Label: "late mac", Active: true,
						})
						if blocked {
							if err == nil {
								t.Errorf("CreateProviderToken succeeded after %s", state)
							}
							if got, err := s.GetProviderToken(raw); err == nil {
								t.Errorf("late provider token remains usable after %s: %+v", state, got)
							}
							return
						}
						if err != nil {
							t.Fatal(err)
						}
						if got, err := s.GetProviderToken(raw); err != nil || got.AccountID != a.AccountID {
							t.Fatalf("new provider token after cancel = %v, %v", got, err)
						}
					})

					t.Run("new_provider", func(t *testing.T) {
						provider := store.ProviderRecord{
							ID: erasurefixture.UniqueID("late-provider"), AccountID: a.AccountID,
							Hardware: []byte(`{}`), Models: []byte(`[]`), Backend: "mlx",
							SerialNumber: "late-personal-serial", SEPublicKey: erasurefixture.UniqueID("late-se-key"),
							Location: &store.ProviderLocation{City: "Lisbon"}, RegisteredAt: now, LastSeen: now,
						}
						err := s.UpsertProvider(ctx, provider)
						if blocked {
							if got, err := s.GetProviderRecord(ctx, provider.ID); err == nil {
								t.Errorf("new provider persisted after %s: %+v", state, got)
							}
							if got, err := s.ListProvidersByAccount(ctx, a.AccountID); err != nil || len(got) != 0 {
								t.Errorf("ListProvidersByAccount after %s = %v, %v; want no live providers", state, got, err)
							}
							return
						}
						if err != nil {
							t.Fatal(err)
						}
						if got, err := s.GetProviderRecord(ctx, provider.ID); err != nil || got.AccountID != a.AccountID {
							t.Fatalf("new provider after cancel = %v, %v", got, err)
						}
					})
				})
			}
		})
	}
}
