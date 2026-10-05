package postgres_test

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5/pgxpool"

	cachemigrations "github.com/eigeninference/d-inference/coordinator/internal/store/cachemigrations"
	"github.com/eigeninference/d-inference/coordinator/store"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// The same contract runs against the memory store and, when DATABASE_URL is
// set (CI provides Postgres 16), against Postgres.
func cacheRoutingStateBackends(t *testing.T) map[string]crs.Store {
	t.Helper()
	backends := map[string]crs.Store{"memory": memory.NewMemory(store.Config{})}
	if pg := testPostgresStoreOrNil(t); pg != nil {
		backends["postgres"] = pg
	}
	return backends
}

func postgresTestAvailable() bool { return os.Getenv("DATABASE_URL") != "" }

// testPostgresStoreOrNil mirrors testPostgresStore without skipping the whole
// test, so the memory half of a contract test still runs without a database.
func testPostgresStoreOrNil(t *testing.T) *postgresFixture {
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

// The durable copy never holds the provider-confirmed chain hash: a boundary
// is named by its keyed identifier and token count only, and the column an
// earlier build of this branch created is dropped by the schema loop.
func TestCacheRoutingHoldersTableStoresNoChainHash(t *testing.T) {
	for name, s := range cacheRoutingStateBackends(t) {
		pg, ok := store.As[*postgresFixture](s)
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
			if _, err := pg.pool.Exec(ctx, cachemigrations.DropChainHashDDL); err != nil {
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
			if _, err := pg.pool.Exec(ctx, cachemigrations.BackfillColumnsDDL); err != nil {
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
	cfg, err := pgxpool.ParseConfig(pg.pool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.Tracer = resetMarkerTracer{cancel: cancel}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	traced := postgres.NewPostgresWithPool(pool)
	defer traced.Close()
	err = traced.ResetCacheRoutingState(interrupted, "gen-2")
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
