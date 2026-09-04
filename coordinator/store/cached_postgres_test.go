package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Composes CachedStore over a real PostgresStore (throwaway DATABASE_URL, see
// harness_test.go) and proves the decorator's invalidation tracks real SQL
// writes, that a real pgx miss is negative-cached, and that an out-of-band
// SQL write is only visible after the TTL -- the documented single-process
// caveat.
func TestCachedStoreOverPostgres(t *testing.T) {
	pg := testPostgresStore(t)
	counting := newCountingStore(pg)
	clock := newFakeClock()
	cfg := DefaultCacheConfig()
	cfg.Now = clock.now
	cached := NewCached(counting, cfg)

	t.Run("users", func(t *testing.T) {
		acct := uniqueID("acct")
		u := &User{AccountID: acct, PrivyUserID: "did:privy:" + acct, Email: acct + "@example.test"}
		if err := cached.CreateUser(u); err != nil {
			t.Fatalf("CreateUser: %v", err)
		}
		for i := 0; i < 3; i++ {
			got, err := cached.GetUserByAccountID(acct)
			if err != nil || got.AccountID != acct || got.Role != "" {
				t.Fatalf("get %d: %+v %v", i, got, err)
			}
			if got, err := cached.GetUserByPrivyID("did:privy:" + acct); err != nil || got.AccountID != acct {
				t.Fatalf("privy get %d: %+v %v", i, got, err)
			}
		}
		if n := counting.count("GetUserByAccountID"); n != 1 {
			t.Fatalf("inner GetUserByAccountID calls = %d, want 1", n)
		}

		// Real UPDATE through the decorator -> next read reflects it.
		if err := cached.SetUserRole(acct, RoleService); err != nil {
			t.Fatalf("SetUserRole: %v", err)
		}
		got, err := cached.GetUserByAccountID(acct)
		if err != nil || got.Role != RoleService {
			t.Fatalf("after SetUserRole: %+v %v", got, err)
		}
		if n := counting.count("GetUserByAccountID"); n != 2 {
			t.Fatalf("inner calls after SetUserRole = %d, want 2", n)
		}
		fee := int64(0)
		if err := cached.SetUserPlatformFeePercent(acct, &fee); err != nil {
			t.Fatalf("SetUserPlatformFeePercent: %v", err)
		}
		if got, _ := cached.GetUserByAccountID(acct); got.PlatformFeePercent == nil || *got.PlatformFeePercent != 0 {
			t.Fatalf("after SetUserPlatformFeePercent: %+v", got)
		}
		if err := cached.SetUserStripeAccount(acct, "acct_pg", "pending", "US", "card", "4242", true); err != nil {
			t.Fatalf("SetUserStripeAccount: %v", err)
		}
		if got, _ := cached.GetUserByAccountID(acct); got.StripeAccountID != "acct_pg" || got.StripeAccountStatus != "pending" {
			t.Fatalf("after SetUserStripeAccount: %+v", got)
		}

		// Out-of-band SQL write: invisible until UserTTL elapses.
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := pg.pool.Exec(ctx, `UPDATE users SET role = '' WHERE account_id = $1`, acct); err != nil {
			t.Fatalf("out-of-band update: %v", err)
		}
		if got, _ := cached.GetUserByAccountID(acct); got.Role != RoleService {
			t.Fatalf("out-of-band write became visible before TTL: %+v", got)
		}
		clock.advance(cfg.UserTTL + time.Millisecond)
		if got, _ := cached.GetUserByAccountID(acct); got.Role != "" {
			t.Fatalf("out-of-band write still invisible after TTL: %+v", got)
		}

		// A real pgx.ErrNoRows miss is negative-cached with the sentinel.
		before := counting.count("GetUserByAccountID")
		for i := 0; i < 3; i++ {
			if _, err := cached.GetUserByAccountID("acct-missing"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("miss %d: %v", i, err)
			}
		}
		if got := counting.count("GetUserByAccountID"); got != before+1 {
			t.Fatalf("negative entry not cached over Postgres: inner calls %d -> %d", before, got)
		}
	})

	t.Run("models", func(t *testing.T) {
		modelID := uniqueID("mlx-community/cached")
		entry, v, files := registryFixture(modelID, "v1")
		if err := cached.SetModelVersion(entry, v, files); err != nil {
			t.Fatalf("SetModelVersion: %v", err)
		}
		if err := cached.PromoteModelVersion(modelID, "v1"); err != nil {
			t.Fatalf("PromoteModelVersion: %v", err)
		}
		for i := 0; i < 3; i++ {
			rec, err := cached.GetModelRegistryRecord(modelID)
			if err != nil || rec.ActiveVersion == nil || rec.ActiveVersion.Version != "v1" || len(rec.Files) != 1 {
				t.Fatalf("record %d: %+v %v", i, rec, err)
			}
			if rec.RuntimeParameters["reasoning_parser"] != "qwen3" {
				t.Fatalf("record %d runtime params: %+v", i, rec.RuntimeParameters)
			}
			m, err := cached.GetModelManifest(modelID)
			if err != nil || m.Version != "v1" || m.AggregateSHA256 != cachedTestHash || len(m.Files) != 1 {
				t.Fatalf("manifest %d: %+v %v", i, m, err)
			}
		}
		if n := counting.count("GetModelRegistryRecord"); n != 1 {
			t.Fatalf("inner GetModelRegistryRecord calls = %d, want 1 (two SQL queries each)", n)
		}
		if n := counting.count("GetModelManifest"); n != 0 {
			t.Fatalf("inner GetModelManifest calls = %d, want 0", n)
		}

		// Real writes through the decorator, each followed by a fresh read.
		entry.DisplayName = "Renamed"
		if err := cached.UpsertModelRegistryEntry(entry); err != nil {
			t.Fatalf("UpsertModelRegistryEntry: %v", err)
		}
		if rec, _ := cached.GetModelRegistryRecord(modelID); rec == nil || rec.DisplayName != "Renamed" {
			t.Fatalf("after upsert: %+v", rec)
		}
		entry2, v2, files2 := registryFixture(modelID, "v2")
		entry2.DisplayName = "Renamed"
		if err := cached.SetModelVersion(entry2, v2, files2); err != nil {
			t.Fatalf("SetModelVersion v2: %v", err)
		}
		if err := cached.PromoteModelVersion(modelID, "v2"); err != nil {
			t.Fatalf("PromoteModelVersion v2: %v", err)
		}
		if m, err := cached.GetModelManifest(modelID); err != nil || m.Version != "v2" || m.R2Prefix != modelID+"/v2" {
			t.Fatalf("after promote v2: %+v %v", m, err)
		}
		if err := cached.SetModelStatus(modelID, "retired"); err != nil {
			t.Fatalf("SetModelStatus: %v", err)
		}
		before := counting.count("GetModelRegistryRecord")
		for i := 0; i < 3; i++ {
			rec, err := cached.GetModelRegistryRecord(modelID)
			if rec != nil || !errors.Is(err, ErrNotFound) {
				t.Fatalf("retired read %d: %+v %v", i, rec, err)
			}
		}
		if got := counting.count("GetModelRegistryRecord"); got != before+1 {
			t.Fatalf("retired miss not negative-cached: inner calls %d -> %d", before, got)
		}
	})
}
