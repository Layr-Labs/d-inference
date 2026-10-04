package store_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestProviderRestoreSelectsLatestPriorIdentity(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			st := store.NewCached(backend, store.DefaultCacheConfig()) // exercise decorator forwarding
			now := time.Now().UTC().Truncate(time.Microsecond)
			// Deliberately insert in a different order from last_seen, including a
			// newest in-progress registration with no inherited counters yet.
			rows := []store.ProviderRecord{
				{ID: "newest-prior", SerialNumber: "serial", SEPublicKey: "key", LastSeen: now, LifetimeTokensGenerated: 700, AccountID: "owner"},
				{ID: "old", SerialNumber: "serial", SEPublicKey: "key", LastSeen: now.Add(-time.Hour), LifetimeTokensGenerated: 5},
				{ID: "current", SerialNumber: "serial", SEPublicKey: "key", LastSeen: now.Add(time.Minute)},
				{ID: "key-only", SerialNumber: "different-serial", SEPublicKey: "fallback", LastSeen: now.Add(time.Hour)},
			}
			for _, p := range rows {
				p.Hardware = json.RawMessage(`{}`)
				p.Models = json.RawMessage(`[]`)
				p.RegisteredAt = now
				if err := st.UpsertProvider(context.Background(), p); err != nil {
					t.Fatal(err)
				}
			}
			latest, err := st.GetProviderForRestore(context.Background(), "serial", "key", nil)
			if err != nil || latest == nil || latest.ID != "current" {
				t.Fatalf("nil exclusions filtered all records: %+v %v", latest, err)
			}
			for _, tc := range []struct{ serial, key, exclude, want string }{
				{"serial", "fallback", "current", "newest-prior"}, // serial takes priority
				{"missing", "fallback", "current", "key-only"},
				{"", "key", "current", "newest-prior"},
				{"", "", "current", ""},
				{"unknown", "unknown", "current", ""},
			} {
				got, err := st.GetProviderForRestore(context.Background(), tc.serial, tc.key, []string{tc.exclude})
				if err != nil {
					t.Fatal(err)
				}
				if tc.want == "" {
					if got != nil {
						t.Fatalf("unexpected match: %+v", got)
					}
					continue
				}
				if got == nil || got.ID != tc.want {
					t.Fatalf("%+v: got %+v", tc, got)
				}
				if tc.want == "newest-prior" && (got.LifetimeTokensGenerated != 700 || got.AccountID != "owner") {
					t.Fatalf("lost state: %+v", got)
				}
			}
		})
	}
}
