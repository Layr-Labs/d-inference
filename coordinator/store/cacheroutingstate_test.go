package store

import (
	"context"
	"fmt"
	"os"
	"sort"
	"testing"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// The same contract runs against the memory store and, when DATABASE_URL is
// set (CI provides Postgres 16), against Postgres.
func cacheRoutingStateBackends(t *testing.T) map[string]crs.Store {
	t.Helper()
	backends := map[string]crs.Store{"memory": NewMemory(Config{})}
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

func clearCacheRoutingState(t *testing.T, s crs.Store) {
	t.Helper()
	if err := s.ResetCacheRoutingState(context.Background(), ""); err != nil {
		t.Fatalf("clear: %v", err)
	}
}

func holderRecord(i int, epoch string, now time.Time, ttl time.Duration) crs.HolderRecord {
	return crs.HolderRecord{
		Key: fmt.Sprintf("k%03d", i), CacheEpoch: epoch, Tier: "ssd", ModelID: "gpt-oss-20b",
		ModelAggregateHash: "aggr", PromptContractID: "contract", BlockHashVersion: "darkbloom-block-chain-v1", ReadyBoundaryMode: "checkpoint",
		AnchorTokenCount:        1024 * (i%8 + 1),
		RequiredRecomputeTokens: 0, StageMs: 120, UpdatedAt: now, ExpiresAt: now.Add(ttl),
	}
}

func TestCacheRoutingStateRoundTripAndMerge(t *testing.T) {
	for name, s := range cacheRoutingStateBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			clearCacheRoutingState(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			var recs []crs.HolderRecord
			for i := 0; i < 700; i++ { // more than one 512-row chunk
				recs = append(recs, holderRecord(i, "epoch-a", now, 29*time.Minute))
			}
			recs = append(recs, holderRecord(0, "epoch-b", now, 29*time.Minute))               // same key, second provider
			recs = append(recs, holderRecord(1, "epoch-a", now.Add(-time.Hour), -time.Minute)) // stale duplicate of k001: older UpdatedAt, already expired
			if err := s.UpsertCacheHolders(ctx, recs); err != nil {
				t.Fatalf("upsert: %v", err)
			}
			got, err := s.LoadCacheHolders(ctx, now, 0, 0)
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if len(got) != 701 {
				t.Fatalf("loaded %d rows, want 701 (700 epoch-a + 1 epoch-b; the stale duplicate must not shorten k001)", len(got))
			}
			byKey := map[crs.HolderKey]crs.HolderRecord{}
			for _, r := range got {
				byKey[r.HolderKey()] = r
			}
			k1 := byKey[crs.HolderKey{Key: "k001", CacheEpoch: "epoch-a"}]
			if !k1.UpdatedAt.Equal(now) || !k1.ExpiresAt.Equal(now.Add(29*time.Minute)) {
				t.Fatalf("older duplicate overwrote the newer row: %+v", k1)
			}
			// A newer receipt refreshes the row; an older one only extends expiry.
			// The newer one carries a measured stage cost, the older none.
			newer := holderRecord(5, "epoch-a", now.Add(time.Minute), 29*time.Minute)
			newer.StageMs = 80
			newer.MeasuredStageMs = 640
			newer.MeasuredExpiresAt = now.Add(20 * time.Minute)
			older := holderRecord(6, "epoch-a", now.Add(-time.Minute), 45*time.Minute)
			older.StageMs = 999
			older.ReadyBoundaryMode = "legacy"
			if err := s.UpsertCacheHolders(ctx, []crs.HolderRecord{newer, older}); err != nil {
				t.Fatalf("merge upsert: %v", err)
			}
			// k005 is updated a minute from now; a load skips rows updated in
			// the future, so read a minute later.
			got, _ = s.LoadCacheHolders(ctx, now.Add(time.Minute), 0, 0)
			byKey = map[crs.HolderKey]crs.HolderRecord{}
			for _, r := range got {
				byKey[r.HolderKey()] = r
			}
			if r := byKey[crs.HolderKey{Key: "k005", CacheEpoch: "epoch-a"}]; r.StageMs != 80 || !r.UpdatedAt.Equal(now.Add(time.Minute)) ||
				r.MeasuredStageMs != 640 || !r.MeasuredExpiresAt.Equal(now.Add(20*time.Minute)) || r.ReadyBoundaryMode != "checkpoint" {
				t.Fatalf("newer receipt (with its measurement) did not win: %+v", r)
			}
			if r := byKey[crs.HolderKey{Key: "k006", CacheEpoch: "epoch-a"}]; r.MeasuredStageMs != 0 || !r.MeasuredExpiresAt.IsZero() {
				t.Fatalf("a row without a measurement must read back zero values: %+v", r)
			}
			if r := byKey[crs.HolderKey{Key: "k006", CacheEpoch: "epoch-a"}]; r.StageMs != 120 || r.ReadyBoundaryMode != "checkpoint" || !r.ExpiresAt.Equal(now.Add(-time.Minute).Add(45*time.Minute)) {
				t.Fatalf("older receipt must keep descriptive columns but extend expiry: %+v", r)
			}
			// A capped load keeps the longest-lived rows: k006 was extended to 44 min.
			top, err := s.LoadCacheHolders(ctx, now, 0, 1)
			if err != nil || len(top) != 1 || top[0].Key != "k006" {
				t.Fatalf("capped load must return the longest-lived row first: %+v %v", top, err)
			}
			// A reduced TTL applies before the order and the cap: read a
			// minute from now under a 5-minute TTL, k006 (updated at now,
			// extended to 44 min) has 4 min left while k005 (updated a minute
			// later) has 5, and the result carries the clamped expiry.
			top, err = s.LoadCacheHolders(ctx, now.Add(time.Minute), 5*time.Minute, 1)
			if err != nil || len(top) != 1 || top[0].Key != "k005" || !top[0].ExpiresAt.Equal(now.Add(6*time.Minute)) {
				t.Fatalf("capped load under a shorter TTL must order by the clamped expiry: %+v %v", top, err)
			}
			if rows, _ := s.LoadCacheHolders(ctx, now.Add(10*time.Minute), 5*time.Minute, 0); len(rows) != 0 {
				t.Fatalf("rows past their clamped expiry must not load: %d", len(rows))
			}
			// Delete a chunk-spanning set of keys.
			var del []crs.HolderKey
			for i := 0; i < 600; i++ {
				del = append(del, crs.HolderKey{Key: fmt.Sprintf("k%03d", i), CacheEpoch: "epoch-a"})
			}
			del = append(del, crs.HolderKey{Key: "missing", CacheEpoch: "epoch-a"})
			if err := s.DeleteCacheHolders(ctx, del); err != nil {
				t.Fatalf("delete: %v", err)
			}
			got, _ = s.LoadCacheHolders(ctx, now, 0, 0)
			if len(got) != 101 { // 100 epoch-a survivors (k600..k699) + k000/epoch-b
				t.Fatalf("after delete %d rows, want 101", len(got))
			}
			// Expired rows are invisible to Load and removed by Prune.
			got, _ = s.LoadCacheHolders(ctx, now.Add(time.Hour), 0, 0)
			if len(got) != 0 {
				t.Fatalf("expired rows must not load: %d", len(got))
			}
			removed, err := s.PruneCacheRoutingState(ctx, now.Add(time.Hour), 0, now.Add(-time.Hour))
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
			var recs []crs.DemandRecord
			for i := 0; i < 1100; i++ {
				recs = append(recs, crs.DemandRecord{Key: fmt.Sprintf("d%04d", i), SeenAt: now.Add(-time.Duration(i) * time.Second)})
			}
			if err := s.UpsertCacheDemand(ctx, recs); err != nil {
				t.Fatalf("upsert: %v", err)
			}
			// Older observation never moves seen_at backwards; newer one advances it.
			if err := s.UpsertCacheDemand(ctx, []crs.DemandRecord{
				{Key: "d0000", SeenAt: now.Add(-time.Hour)},
				{Key: "d0001", SeenAt: now.Add(time.Minute)},
			}); err != nil {
				t.Fatalf("merge: %v", err)
			}
			// A row stamped after the load's upper bound (a previous instance's
			// fast clock) is invisible to a bounded load.
			if err := s.UpsertCacheDemand(ctx, []crs.DemandRecord{{Key: "future", SeenAt: now.Add(2 * time.Hour)}}); err != nil {
				t.Fatalf("upsert future row: %v", err)
			}
			if rows, err := s.LoadCacheDemand(ctx, now.Add(-600*time.Second), now, 1); err != nil || len(rows) != 1 || rows[0].Key == "future" {
				t.Fatalf("future row must not take the cap: %+v %v", rows, err)
			}
			// Inside the skew tolerance a row loads, clamped to the bound.
			if err := s.UpsertCacheDemand(ctx, []crs.DemandRecord{{Key: "slight", SeenAt: now.Add(30 * time.Second)}}); err != nil {
				t.Fatal(err)
			}
			within, err := s.LoadCacheDemand(ctx, now.Add(-600*time.Second), now, 0)
			if err != nil {
				t.Fatal(err)
			}
			clamped := map[string]time.Time{}
			for _, r := range within {
				clamped[r.Key] = r.SeenAt
			}
			if !clamped["slight"].Equal(now) || !clamped["d0001"].Equal(now) {
				t.Fatalf("rows within the skew tolerance must load with their seen time clamped: %+v", clamped)
			}
			// The prune removes it so a current observation is not outranked.
			if removed, err := s.PruneCacheRoutingState(ctx, now, 0, now.Add(-2*time.Hour)); err != nil || removed != 1 {
				t.Fatalf("prune must remove the future-dated demand row: removed=%d err=%v", removed, err)
			}
			if err := s.UpsertCacheDemand(ctx, []crs.DemandRecord{{Key: "future", SeenAt: now}}); err != nil {
				t.Fatal(err)
			}
			rows, _ := s.LoadCacheDemand(ctx, now.Add(-time.Second), now, 0)
			replaced := false
			for _, r := range rows {
				if r.Key == "future" && r.SeenAt.Equal(now) {
					replaced = true
				}
			}
			if !replaced {
				t.Fatalf("a current observation must replace the pruned future row: %+v", rows)
			}
			got, err := s.LoadCacheDemand(ctx, now.Add(-600*time.Second), now.Add(time.Hour), 0)
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if len(got) != 603 { // 601 + the "future" key re-observed at now + "slight"
				t.Fatalf("loaded %d rows within the window, want 603", len(got))
			}
			sort.Slice(got, func(i, j int) bool { return got[i].Key < got[j].Key })
			if !got[0].SeenAt.Equal(now) || !got[1].SeenAt.Equal(now.Add(time.Minute)) {
				t.Fatalf("merge semantics wrong: %v %v", got[0].SeenAt, got[1].SeenAt)
			}
			// A capped load keeps the newest keys.
			top, err := s.LoadCacheDemand(ctx, now.Add(-600*time.Second), now.Add(time.Hour), 2)
			if err != nil || len(top) != 2 || top[0].Key != "d0001" || top[1].Key != "slight" {
				t.Fatalf("capped demand load must return the newest keys first: %+v %v", top, err)
			}
			removed, err := s.PruneCacheRoutingState(ctx, now, 0, now.Add(-600*time.Second))
			if err != nil || removed != 499 {
				t.Fatalf("prune removed %d (err %v), want 499", removed, err)
			}
			// A row updated after the load's clock (a previous instance ran
			// ahead) is skipped until the clock catches up with it.
			skew := holderRecord(900, "epoch-skew", now.Add(time.Hour), 29*time.Minute)
			if err := s.UpsertCacheHolders(ctx, []crs.HolderRecord{skew}); err != nil {
				t.Fatalf("upsert skewed row: %v", err)
			}
			if rows, _ := s.LoadCacheHolders(ctx, now, 0, 0); len(rows) != 0 {
				t.Fatalf("a row updated in the future must not load: %+v", rows)
			}
			// Inside the skew tolerance it loads, clamped to the load's clock.
			slight := holderRecord(901, "epoch-slight", now.Add(30*time.Second), 29*time.Minute)
			if err := s.UpsertCacheHolders(ctx, []crs.HolderRecord{slight}); err != nil {
				t.Fatal(err)
			}
			if rows, _ := s.LoadCacheHolders(ctx, now, 0, 0); len(rows) != 1 || rows[0].Key != "k901" || !rows[0].UpdatedAt.Equal(now) {
				t.Fatalf("a row within the skew tolerance must load with its update time clamped: %+v", rows)
			}
			if err := s.DeleteCacheHolders(ctx, []crs.HolderKey{slight.HolderKey()}); err != nil {
				t.Fatal(err)
			}
			if rows, _ := s.LoadCacheHolders(ctx, now.Add(61*time.Minute), 0, 0); len(rows) != 1 || rows[0].Key != "k900" {
				t.Fatalf("the skewed row loads once the clock has passed its update: %+v", rows)
			}
			// A prune removes it (it is more than FutureSkew ahead), so a
			// current receipt for the same key is not outranked by it.
			if removed, err := s.PruneCacheRoutingState(ctx, now, 0, now.Add(-time.Hour)); err != nil || removed != 1 {
				t.Fatalf("prune must remove the future-dated row: removed=%d err=%v", removed, err)
			}
			current := holderRecord(900, "epoch-skew", now, 29*time.Minute)
			if err := s.UpsertCacheHolders(ctx, []crs.HolderRecord{current}); err != nil {
				t.Fatal(err)
			}
			if rows, _ := s.LoadCacheHolders(ctx, now, 0, 0); len(rows) != 1 || !rows[0].UpdatedAt.Equal(now) {
				t.Fatalf("a current receipt must replace the pruned future row: %+v", rows)
			}
			if err := s.DeleteCacheHolders(ctx, []crs.HolderKey{current.HolderKey()}); err != nil {
				t.Fatal(err)
			}
			// Pruning under the active TTL removes rows a longer past TTL left
			// with a distant stored expiry once their effective expiry has
			// passed, and keeps rows still live under it.
			stale := holderRecord(901, "epoch-stale", now.Add(-40*time.Minute), 60*time.Minute) // effective now-11m under 29m
			live := holderRecord(902, "epoch-live", now.Add(-5*time.Minute), 60*time.Minute)    // effective now+24m
			if err := s.UpsertCacheHolders(ctx, []crs.HolderRecord{stale, live}); err != nil {
				t.Fatalf("upsert prune fixtures: %v", err)
			}
			if removed, err := s.PruneCacheRoutingState(ctx, now, 29*time.Minute, now.Add(-time.Hour)); err != nil || removed != 1 {
				t.Fatalf("prune under the active TTL removed %d (err %v), want 1", removed, err)
			}
			if rows, _ := s.LoadCacheHolders(ctx, now, 0, 0); len(rows) != 1 || rows[0].Key != "k902" {
				t.Fatalf("prune under the active TTL must keep the live row only: %+v", rows)
			}
			// Key rotation: reset empties both tables, whatever the rows' expiry
			// (a TTL above 1,000 hours is a legal configuration), and records
			// the generation.
			far := holderRecord(0, "epoch-far", now, 2000*time.Hour)
			if err := s.UpsertCacheHolders(ctx, []crs.HolderRecord{far}); err != nil {
				t.Fatalf("upsert far-future row: %v", err)
			}
			if fp, err := s.CacheRoutingKeyFingerprint(ctx); err != nil || fp != "" {
				t.Fatalf("fingerprint before reset: %q %v", fp, err)
			}
			if err := s.ResetCacheRoutingState(ctx, "gen-2"); err != nil {
				t.Fatalf("reset: %v", err)
			}
			if rest, _ := s.LoadCacheHolders(ctx, now, 0, 0); len(rest) != 0 {
				t.Fatalf("reset must empty the holder table regardless of expiry: %+v", rest)
			}
			if fp, _ := s.CacheRoutingKeyFingerprint(ctx); fp != "gen-2" {
				t.Fatalf("fingerprint after reset: %q", fp)
			}
			if rest, _ := s.LoadCacheDemand(ctx, now.Add(-time.Hour), now.Add(time.Hour), 0); len(rest) != 0 {
				t.Fatalf("reset must empty the demand table: %d rows", len(rest))
			}
		})
	}
}

func TestCacheRoutingStateRejectsInvalidRecords(t *testing.T) {
	s := NewMemory(Config{})
	ctx := context.Background()
	if err := s.UpsertCacheHolders(ctx, []crs.HolderRecord{{Key: "k", CacheEpoch: ""}}); err == nil {
		t.Fatal("holder without epoch must be rejected")
	}
	if err := s.UpsertCacheDemand(ctx, []crs.DemandRecord{{Key: ""}}); err == nil {
		t.Fatal("demand without key must be rejected")
	}
	if err := s.UpsertCacheHolders(ctx, nil); err != nil {
		t.Fatalf("empty batch must be a no-op: %v", err)
	}
}

// The durable copy never holds the provider-confirmed chain hash: a boundary
// is named by its keyed identifier and token count only, and the column an
// earlier build of this branch created is dropped by the schema loop.
func TestCacheRoutingHoldersTableStoresNoChainHash(t *testing.T) {
	for name, s := range cacheRoutingStateBackends(t) {
		pg, ok := As[*PostgresStore](s)
		if !ok {
			continue
		}
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			count := func() int {
				var n int
				if err := pg.pool.QueryRow(ctx,
					`SELECT count(*) FROM information_schema.columns WHERE table_name = 'cache_routing_holders' AND column_name = 'anchor_chain_hash'`).Scan(&n); err != nil {
					t.Fatal(err)
				}
				return n
			}
			if count() != 0 {
				t.Fatal("anchor_chain_hash exists after the schema loop")
			}
			// A table an earlier build created carries the column; the
			// schema loop's drop removes it, and its values with it.
			if _, err := pg.pool.Exec(ctx, `ALTER TABLE cache_routing_holders ADD COLUMN IF NOT EXISTS anchor_chain_hash TEXT NOT NULL DEFAULT ''`); err != nil {
				t.Fatal(err)
			}
			if count() != 1 {
				t.Fatal("fixture column missing")
			}
			if _, err := pg.pool.Exec(ctx, cacheRoutingHoldersDropChainHashDDL); err != nil {
				t.Fatalf("drop migration: %v", err)
			}
			if count() != 0 {
				t.Fatal("the drop migration must remove anchor_chain_hash")
			}
			// The other direction: a table from before a column existed
			// picks it up from the backfill ALTER, and rows load afterwards.
			if _, err := pg.pool.Exec(ctx, `ALTER TABLE cache_routing_holders DROP COLUMN IF EXISTS ready_boundary_mode`); err != nil {
				t.Fatal(err)
			}
			if _, err := pg.pool.Exec(ctx, cacheRoutingHoldersBackfillColumnsDDL); err != nil {
				t.Fatalf("backfill migration: %v", err)
			}
			var n int
			if err := pg.pool.QueryRow(ctx,
				`SELECT count(*) FROM information_schema.columns WHERE table_name = 'cache_routing_holders' AND column_name = 'ready_boundary_mode'`).Scan(&n); err != nil || n != 1 {
				t.Fatalf("backfill must add ready_boundary_mode: n=%d err=%v", n, err)
			}
			now := time.Now()
			if err := pg.UpsertCacheHolders(ctx, []crs.HolderRecord{holderRecord(1, "epoch-backfill", now, time.Minute)}); err != nil {
				t.Fatal(err)
			}
			if rows, err := pg.LoadCacheHolders(ctx, now, 0, 0); err != nil || len(rows) == 0 {
				t.Fatalf("load after backfill: %+v %v", rows, err)
			}
			_, _ = pg.PruneCacheRoutingState(ctx, now.Add(2*time.Minute), 0, now.Add(2*time.Minute))
		})
	}
}

// A reset interrupted after its marker and before its deletes leaves the
// marker as the recorded generation, so a boot reads the reset as unfinished
// and repeats it; the retry completes it.
func TestCacheRoutingStateResetLeavesMarkerWhenInterrupted(t *testing.T) {
	pg := testPostgresStoreOrNil(t)
	if pg == nil {
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	clearCacheRoutingState(t, pg)
	now := time.Now()
	if err := pg.UpsertCacheHolders(ctx, []crs.HolderRecord{holderRecord(0, "epoch", now, time.Hour)}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	interrupted, cancel := context.WithCancel(ctx)
	defer cancel()
	pg.afterCacheRoutingResetMarker = cancel
	err := pg.ResetCacheRoutingState(interrupted, "gen-2")
	pg.afterCacheRoutingResetMarker = nil
	if err == nil {
		t.Fatal("a reset interrupted after its marker must report the failure")
	}
	if fp, err := pg.CacheRoutingKeyFingerprint(ctx); err != nil || fp != crs.ResetInProgress {
		t.Fatalf("an interrupted reset must leave the marker recorded: %q %v", fp, err)
	}
	if rows, err := pg.LoadCacheHolders(ctx, now, 0, 0); err != nil || len(rows) != 1 {
		t.Fatalf("the interrupted reset stopped before its deletes: %d rows, %v", len(rows), err)
	}
	if err := pg.ResetCacheRoutingState(ctx, "gen-2"); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if fp, _ := pg.CacheRoutingKeyFingerprint(ctx); fp != "gen-2" {
		t.Fatalf("the completed reset must record the generation: %q", fp)
	}
	if rows, err := pg.LoadCacheHolders(ctx, now, 0, 0); err != nil || len(rows) != 0 {
		t.Fatalf("the completed reset must empty the table: %d rows, %v", len(rows), err)
	}
}
