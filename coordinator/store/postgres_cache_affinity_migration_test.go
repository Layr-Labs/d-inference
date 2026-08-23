package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)
func TestLegacyCacheAffinityMigrationScrubsAndInstallsScopedTrigger(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	schema := fmt.Sprintf("cache_affinity_migration_%d", time.Now().UnixNano())
	if _, err := s.pool.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatalf("create isolated schema: %v", err)
	}
	t.Cleanup(func() {
		_, _ = s.pool.Exec(context.Background(), "DROP SCHEMA IF EXISTS "+schema+" CASCADE")
	})

	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire isolated migration connection: %v", err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "SET search_path TO "+schema); err != nil {
		t.Fatalf("set isolated search_path: %v", err)
	}
	for _, statement := range []string{
		`CREATE TABLE schema_migrations (
			id TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE inference_routes (
			id BIGSERIAL PRIMARY KEY,
			cache_affinity_key TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE trigger_name_conflict (
			id BIGSERIAL PRIMARY KEY,
			cache_affinity_key TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE FUNCTION clear_legacy_cache_affinity_key()
			RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$`,
		`CREATE TRIGGER clear_legacy_cache_affinity_key
			BEFORE INSERT OR UPDATE OF cache_affinity_key ON trigger_name_conflict
			FOR EACH ROW EXECUTE FUNCTION clear_legacy_cache_affinity_key()`,
		`INSERT INTO inference_routes (cache_affinity_key) VALUES ('legacy-secret')`,
	} {
		if _, err := conn.Exec(ctx, statement); err != nil {
			t.Fatalf("prepare legacy schema: %v\n%s", err, statement)
		}
	}

	for _, migration := range []string{
		legacyCacheAffinityGuardFunction,
		legacyCacheAffinityGuardTrigger,
		legacyCacheAffinityScrubMigration,
	} {
		if _, err := conn.Exec(ctx, migration); err != nil {
			t.Fatalf("run cache-affinity migration: %v\n%s", err, migration)
		}
	}

	var scrubbed string
	if err := conn.QueryRow(ctx,
		"SELECT cache_affinity_key FROM inference_routes").Scan(&scrubbed); err != nil {
		t.Fatalf("read scrubbed route: %v", err)
	}
	if scrubbed != "" {
		t.Fatalf("legacy cache affinity survived migration: %q", scrubbed)
	}
	var marked bool
	if err := conn.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM schema_migrations
			WHERE id = 'scrub_inference_route_cache_affinity_v1'
		)`).Scan(&marked); err != nil {
		t.Fatalf("read scrub marker: %v", err)
	}
	if !marked {
		t.Fatal("legacy cache-affinity scrub marker was not recorded")
	}
	var triggerCount int
	if err := conn.QueryRow(ctx, `
		SELECT count(*)
		FROM pg_trigger tg
		JOIN pg_class target ON target.oid = tg.tgrelid
		JOIN pg_namespace ns ON ns.oid = target.relnamespace
		WHERE tg.tgname = 'clear_legacy_cache_affinity_key'
		  AND NOT tg.tgisinternal
		  AND ns.nspname = current_schema()
		`).Scan(&triggerCount); err != nil {
		t.Fatalf("count scoped triggers: %v", err)
	}
	if triggerCount != 2 {
		t.Fatalf("scoped trigger count = %d, want conflict table + inference_routes", triggerCount)
	}

	var inserted, updated string
	if err := conn.QueryRow(ctx, `
		INSERT INTO inference_routes (cache_affinity_key)
		VALUES ('new-secret')
		RETURNING cache_affinity_key`).Scan(&inserted); err != nil {
		t.Fatalf("insert guarded route: %v", err)
	}
	if err := conn.QueryRow(ctx, `
		UPDATE inference_routes
		SET cache_affinity_key = 'replacement-secret'
		RETURNING cache_affinity_key`).Scan(&updated); err != nil {
		t.Fatalf("update guarded route: %v", err)
	}
	if inserted != "" || updated != "" {
		t.Fatalf("trigger did not scrub future writes: insert=%q update=%q", inserted, updated)
	}

	// A restart must remain idempotent with both same-named triggers present.
	for _, migration := range []string{
		legacyCacheAffinityGuardFunction,
		legacyCacheAffinityGuardTrigger,
		legacyCacheAffinityScrubMigration,
	} {
		if _, err := conn.Exec(ctx, migration); err != nil {
			t.Fatalf("re-run cache-affinity migration: %v", err)
		}
	}
}
