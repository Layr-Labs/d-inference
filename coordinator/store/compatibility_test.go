package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// Exercise a caller that retains the facade while composing a direct backend
// with the cache. A copied sentinel or wrapper type breaks this boundary.
func TestFacadePreservesBackendIdentityAndOptionalCapabilities(t *testing.T) {
	type dueJobs interface {
		ListDueVerificationJobsPage(context.Context, time.Time, int, int) ([]contracts.VerificationJob, error)
	}
	for name, backend := range map[string]*store.MemoryStore{
		"facade": store.NewMemory(store.Config{}),
		"direct": memory.New(contracts.Config{}),
	} {
		t.Run(name, func(t *testing.T) {
			cached := store.NewCached(backend, store.CacheConfig{})
			if cached.Unwrap() != backend {
				t.Fatal("facade cache changed the backend identity")
			}
			for i := 0; i < 2; i++ {
				_, err := cached.GetUserByAccountID("missing")
				if !errors.Is(err, store.ErrNotFound) || !errors.Is(err, contracts.ErrNotFound) {
					t.Fatalf("lookup %d lost shared not-found identity: %v", i, err)
				}
			}
			var narrow store.ProviderStore = store.NewCached(cached, store.CacheConfig{})
			capability, ok := store.As[dueJobs](narrow)
			if !ok || any(capability) != any(backend) {
				t.Fatalf("optional capability resolved to %T, want original backend", capability)
			}
			if err := cached.CreateUser(&store.User{AccountID: "missing", PrivyUserID: "did:fixture"}); err != nil {
				t.Fatal(err)
			}
			user, err := cached.GetUserByAccountID("missing")
			if err != nil || user.PrivyUserID != "did:fixture" {
				t.Fatalf("facade write did not invalidate the negative cache: %+v, %v", user, err)
			}
		})
	}
	for name, pair := range map[string][2]error{
		"balance":         {store.ErrInsufficientBalance, contracts.ErrInsufficientBalance},
		"payout conflict": {store.ErrPayoutConflict, contracts.ErrPayoutConflict},
		"quote expired":   {store.ErrPayoutQuoteExpired, contracts.ErrPayoutQuoteExpired},
	} {
		if pair[0] != pair[1] {
			t.Errorf("%s sentinel identity differs between facade and contracts", name)
		}
	}
}
