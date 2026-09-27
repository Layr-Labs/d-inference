package store

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestProviderRestoreSelectsLatestPriorIdentity(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			st := NewCached(backend, DefaultCacheConfig()) // exercise decorator forwarding
			now := time.Now().UTC().Truncate(time.Microsecond)
			// Deliberately insert in a different order from last_seen, including a
			// newest in-progress registration with no inherited counters yet.
			rows := []ProviderRecord{
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

func TestListProviderRecordsRejectsPartialScan(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	s, err := NewPostgres(context.Background(), Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now()
	for i, id := range []string{"good", "bad"} {
		if err := s.UpsertProvider(context.Background(), ProviderRecord{ID: id, Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), RegisteredAt: now, LastSeen: now.Add(-time.Duration(i) * time.Minute)}); err != nil {
			t.Fatal(err)
		}
	}
	// Deliberately malformed private test schema: the first row scans, then the
	// next cannot decode. Returning the already-read row would be silent data loss.
	if _, err := s.pool.Exec(context.Background(), `ALTER TABLE providers ALTER COLUMN failed_challenges TYPE TEXT USING failed_challenges::text; UPDATE providers SET failed_challenges='invalid' WHERE id='bad'`); err != nil {
		t.Fatal(err)
	}
	rows, err := s.ListProviderRecords(context.Background())
	if err == nil || rows != nil {
		t.Fatalf("partial success: rows=%v error=%v", rows, err)
	}
}

func TestProviderAndReputationPublicationIsAtomic(t *testing.T) {
	ctx := context.Background()
	s, err := NewPostgres(ctx, Config{DatabaseURL: newWithdrawableTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.pool.Exec(ctx, `ALTER TABLE provider_reputation ADD CONSTRAINT valid_restore_jobs CHECK(total_jobs >= 0)`); err != nil {
		t.Fatal(err)
	}
	rec := ProviderRecord{ID: "completed", SerialNumber: "serial", Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), RegisteredAt: time.Now(), LastSeen: time.Now(), LifetimeTokensGenerated: 700}
	if err := s.UpsertProviderWithReputation(ctx, rec, ReputationRecord{TotalJobs: -1}); err == nil {
		t.Fatal("expected reputation failure")
	}
	if got, err := s.GetProviderForRestore(ctx, "serial", "", nil); err != nil || got != nil {
		t.Fatalf("identity escaped failed reputation transaction: %+v %v", got, err)
	}
	cached := NewCached(s, DefaultCacheConfig())
	if err := cached.UpsertProviderWithReputation(ctx, rec, ReputationRecord{TotalJobs: 12}); err != nil {
		t.Fatal(err)
	}
	got, err := cached.GetProviderForRestore(ctx, "serial", "", nil)
	if err != nil || got == nil || got.LifetimeTokensGenerated != 700 {
		t.Fatalf("missing completed record: %+v %v", got, err)
	}
	rep, err := cached.GetReputation(ctx, got.ID)
	if err != nil || rep.TotalJobs != 12 {
		t.Fatalf("missing completed reputation: %+v %v", rep, err)
	}
}
