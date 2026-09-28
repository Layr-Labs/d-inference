package store

import (
	"context"
	"fmt"
	"os"
	"sort"
	"testing"
	"time"
)

// The same contract runs against the memory store and, when DATABASE_URL is
// set (CI provides Postgres 16), against Postgres.
func cacheRoutingStateBackends(t *testing.T) map[string]CacheRoutingStateStore {
	t.Helper()
	backends := map[string]CacheRoutingStateStore{"memory": NewMemory(Config{})}
	if pg := testPostgresStoreOrNil(t); pg != nil {
		backends["postgres"] = pg
	}
	return backends
}

func postgresTestAvailable() bool { return os.Getenv("DATABASE_URL") != "" }

// testPostgresStoreOrNil mirrors testPostgresStore without skipping the whole
// test, so the memory half of a contract test still runs without a database.
func testPostgresStoreOrNil(t *testing.T) *PostgresStore {
	t.Helper()
	if !postgresTestAvailable() {
		return nil
	}
	return testPostgresStore(t)
}

func clearCacheRoutingState(t *testing.T, s CacheRoutingStateStore) {
	t.Helper()
	far := time.Now().Add(1000 * time.Hour)
	if _, err := s.PruneCacheRoutingState(context.Background(), far, far); err != nil {
		t.Fatalf("clear: %v", err)
	}
}

func holderRecord(i int, epoch string, now time.Time, ttl time.Duration) CacheHolderRecord {
	return CacheHolderRecord{
		Key: fmt.Sprintf("k%03d", i), CacheEpoch: epoch, Tier: "ssd", ModelID: "gpt-oss-20b",
		ModelAggregateHash: "aggr", PromptContractID: "contract", BlockHashVersion: "darkbloom-block-chain-v1",
		AnchorChainHash: fmt.Sprintf("chain%03d", i), AnchorTokenCount: 1024 * (i%8 + 1),
		RequiredRecomputeTokens: 0, StageMs: 120, UpdatedAt: now, ExpiresAt: now.Add(ttl),
	}
}

func TestCacheRoutingStateRoundTripAndMerge(t *testing.T) {
	for name, s := range cacheRoutingStateBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			clearCacheRoutingState(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			var recs []CacheHolderRecord
			for i := 0; i < 700; i++ { // more than one 512-row chunk
				recs = append(recs, holderRecord(i, "epoch-a", now, 29*time.Minute))
			}
			recs = append(recs, holderRecord(0, "epoch-b", now, 29*time.Minute))               // same key, second provider
			recs = append(recs, holderRecord(1, "epoch-a", now.Add(-time.Hour), -time.Minute)) // stale duplicate of k001: older UpdatedAt, already expired
			if err := s.UpsertCacheHolders(ctx, recs); err != nil {
				t.Fatalf("upsert: %v", err)
			}
			got, err := s.LoadCacheHolders(ctx, now)
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if len(got) != 701 {
				t.Fatalf("loaded %d rows, want 701 (700 epoch-a + 1 epoch-b; the stale duplicate must not shorten k001)", len(got))
			}
			byKey := map[CacheHolderKey]CacheHolderRecord{}
			for _, r := range got {
				byKey[r.HolderKey()] = r
			}
			k1 := byKey[CacheHolderKey{Key: "k001", CacheEpoch: "epoch-a"}]
			if !k1.UpdatedAt.Equal(now) || !k1.ExpiresAt.Equal(now.Add(29*time.Minute)) {
				t.Fatalf("older duplicate overwrote the newer row: %+v", k1)
			}
			// A newer receipt refreshes the row; an older one only extends expiry.
			newer := holderRecord(5, "epoch-a", now.Add(time.Minute), 29*time.Minute)
			newer.StageMs = 80
			older := holderRecord(6, "epoch-a", now.Add(-time.Minute), 45*time.Minute)
			older.StageMs = 999
			if err := s.UpsertCacheHolders(ctx, []CacheHolderRecord{newer, older}); err != nil {
				t.Fatalf("merge upsert: %v", err)
			}
			got, _ = s.LoadCacheHolders(ctx, now)
			byKey = map[CacheHolderKey]CacheHolderRecord{}
			for _, r := range got {
				byKey[r.HolderKey()] = r
			}
			if r := byKey[CacheHolderKey{Key: "k005", CacheEpoch: "epoch-a"}]; r.StageMs != 80 || !r.UpdatedAt.Equal(now.Add(time.Minute)) {
				t.Fatalf("newer receipt did not win: %+v", r)
			}
			if r := byKey[CacheHolderKey{Key: "k006", CacheEpoch: "epoch-a"}]; r.StageMs != 120 || !r.ExpiresAt.Equal(now.Add(-time.Minute).Add(45*time.Minute)) {
				t.Fatalf("older receipt must keep descriptive columns but extend expiry: %+v", r)
			}
			// Delete a chunk-spanning set of keys.
			var del []CacheHolderKey
			for i := 0; i < 600; i++ {
				del = append(del, CacheHolderKey{Key: fmt.Sprintf("k%03d", i), CacheEpoch: "epoch-a"})
			}
			del = append(del, CacheHolderKey{Key: "missing", CacheEpoch: "epoch-a"})
			if err := s.DeleteCacheHolders(ctx, del); err != nil {
				t.Fatalf("delete: %v", err)
			}
			got, _ = s.LoadCacheHolders(ctx, now)
			if len(got) != 101 { // 100 epoch-a survivors (k600..k699) + k000/epoch-b
				t.Fatalf("after delete %d rows, want 101", len(got))
			}
			// Expired rows are invisible to Load and removed by Prune.
			got, _ = s.LoadCacheHolders(ctx, now.Add(time.Hour))
			if len(got) != 0 {
				t.Fatalf("expired rows must not load: %d", len(got))
			}
			removed, err := s.PruneCacheRoutingState(ctx, now.Add(time.Hour), now.Add(-time.Hour))
			if err != nil || removed != 101 {
				t.Fatalf("prune removed %d (err %v), want 101", removed, err)
			}
		})
	}
}

func TestCacheRoutingDemandRoundTrip(t *testing.T) {
	for name, s := range cacheRoutingStateBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			clearCacheRoutingState(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			var recs []CacheDemandRecord
			for i := 0; i < 1100; i++ {
				recs = append(recs, CacheDemandRecord{Key: fmt.Sprintf("d%04d", i), SeenAt: now.Add(-time.Duration(i) * time.Second)})
			}
			if err := s.UpsertCacheDemand(ctx, recs); err != nil {
				t.Fatalf("upsert: %v", err)
			}
			// Older observation never moves seen_at backwards; newer one advances it.
			if err := s.UpsertCacheDemand(ctx, []CacheDemandRecord{
				{Key: "d0000", SeenAt: now.Add(-time.Hour)},
				{Key: "d0001", SeenAt: now.Add(time.Minute)},
			}); err != nil {
				t.Fatalf("merge: %v", err)
			}
			got, err := s.LoadCacheDemand(ctx, now.Add(-600*time.Second))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if len(got) != 601 {
				t.Fatalf("loaded %d rows within the window, want 601", len(got))
			}
			sort.Slice(got, func(i, j int) bool { return got[i].Key < got[j].Key })
			if !got[0].SeenAt.Equal(now) || !got[1].SeenAt.Equal(now.Add(time.Minute)) {
				t.Fatalf("merge semantics wrong: %v %v", got[0].SeenAt, got[1].SeenAt)
			}
			removed, err := s.PruneCacheRoutingState(ctx, now, now.Add(-600*time.Second))
			if err != nil || removed != 499 {
				t.Fatalf("prune removed %d (err %v), want 499", removed, err)
			}
		})
	}
}

func TestCacheRoutingStateRejectsInvalidRecords(t *testing.T) {
	s := NewMemory(Config{})
	ctx := context.Background()
	if err := s.UpsertCacheHolders(ctx, []CacheHolderRecord{{Key: "k", CacheEpoch: ""}}); err == nil {
		t.Fatal("holder without epoch must be rejected")
	}
	if err := s.UpsertCacheDemand(ctx, []CacheDemandRecord{{Key: ""}}); err == nil {
		t.Fatal("demand without key must be rejected")
	}
	if err := s.UpsertCacheHolders(ctx, nil); err != nil {
		t.Fatalf("empty batch must be a no-op: %v", err)
	}
}
