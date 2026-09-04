package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

// TestPostgresDropRedundantRouteIndexIsBoundedAndNonFatal: a second session
// holds an open transaction that has read inference_routes (the shape of an
// idle-in-transaction psql session or a long research query at deploy
// time). DROP INDEX CONCURRENTLY waits for every transaction that could
// still use the index, so it cannot finish while that transaction is open.
// The drop must give up inside routeIndexDropTimeout with an error, the
// boot-time wrapper must swallow that error (the coordinator boots; the
// index stays, marked INVALID by the interrupted drop, and is retried on the
// next boot), and once the blocker ends the next drop succeeds. Before the
// change the drop waited for as long as the transaction stayed open and its
// error failed NewPostgres (os.Exit(1) in main.go): the bounded call below
// hung on that tree.
//
// The drop is exercised directly rather than through migrate: migrate's
// unguarded `ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS` steps
// take ACCESS EXCLUSIVE even when the column exists and block behind the
// same open transaction — a pre-existing boot hazard outside this change.
func TestPostgresDropRedundantRouteIndexIsBoundedAndNonFatal(t *testing.T) {
	s := testPostgresStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if _, err := s.pool.Exec(ctx, `CREATE INDEX IF NOT EXISTS idx_inference_routes_request ON inference_routes(request_id)`); err != nil {
		t.Fatalf("recreate legacy index: %v", err)
	}

	blocker, err := s.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Release()
	tx, err := blocker.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // rolled back explicitly below; this covers early Fatal exits
	var n int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM inference_routes`).Scan(&n); err != nil {
		t.Fatal(err)
	}

	prev := routeIndexDropTimeout
	routeIndexDropTimeout = 2 * time.Second
	defer func() { routeIndexDropTimeout = prev }()

	indexState := func() (present, valid bool) {
		t.Helper()
		if err := s.pool.QueryRow(ctx, `
			SELECT true, i.indisvalid FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
			WHERE c.relname = $1`, redundantRouteIndexName).Scan(&present, &valid); err != nil {
			return false, false
		}
		return present, valid
	}
	bounded := func(name string, call func() error) error {
		t.Helper()
		start := time.Now()
		done := make(chan error, 1)
		go func() { done <- call() }()
		select {
		case err := <-done:
			if elapsed := time.Since(start); elapsed > 15*time.Second {
				t.Fatalf("%s took %v with a %v bound", name, elapsed, routeIndexDropTimeout)
			}
			return err
		case <-time.After(20 * time.Second):
			t.Fatalf("%s hung behind an open transaction on inference_routes", name)
			return nil
		}
	}

	if err := bounded("dropRedundantRouteIndex", func() error { return s.dropRedundantRouteIndex(ctx) }); err == nil {
		t.Fatal("blocked drop returned nil; want the lock/statement timeout error")
	}
	if present, _ := indexState(); !present {
		t.Fatal("index vanished while a transaction still held inference_routes open")
	}
	// The boot-time wrapper swallows the error: nothing for migrate to fail on.
	_ = bounded("retireRedundantRouteIndex", func() error { s.retireRedundantRouteIndex(ctx); return nil })

	// The blocker ends; the next boot's drop succeeds (an interrupted
	// CONCURRENT drop leaves the index INVALID, which IF EXISTS still drops).
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	if err := s.dropRedundantRouteIndex(ctx); err != nil {
		t.Fatalf("drop after the blocker ended: %v", err)
	}
	if present, valid := indexState(); present {
		t.Fatalf("index still present after the blocker ended (valid=%v)", valid)
	}

	// The hijacked session's timeouts never leaked into the pool.
	var lockTimeout, stmtTimeout string
	if err := s.pool.QueryRow(ctx, `SHOW lock_timeout`).Scan(&lockTimeout); err != nil {
		t.Fatal(err)
	}
	if err := s.pool.QueryRow(ctx, `SHOW statement_timeout`).Scan(&stmtTimeout); err != nil {
		t.Fatal(err)
	}
	if lockTimeout != "0" || stmtTimeout != "0" {
		t.Fatalf("pooled session timeouts = (%q, %q) after the bounded drop, want (0, 0)", lockTimeout, stmtTimeout)
	}
}

// TestPostgresMigrateDropsRedundantRouteIndex: after migrate the single-column
// idx_inference_routes_request is gone, the unique (request_id, attempt)
// index serves request_id lookups, and a second migrate is a no-op.
func TestPostgresMigrateDropsRedundantRouteIndex(t *testing.T) {
	s := testPostgresStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	// Recreate the legacy index the way older schemas carried it, then run
	// migrate again: the drop must be exercised, not just skipped.
	if _, err := s.pool.Exec(ctx, `CREATE INDEX IF NOT EXISTS idx_inference_routes_request ON inference_routes(request_id)`); err != nil {
		t.Fatalf("recreate legacy index: %v", err)
	}
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	indexes := func() map[string]bool {
		rows, err := s.pool.Query(ctx, `SELECT indexname FROM pg_indexes WHERE tablename = 'inference_routes'`)
		if err != nil {
			t.Fatalf("pg_indexes: %v", err)
		}
		defer rows.Close()
		out := map[string]bool{}
		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				t.Fatal(err)
			}
			out[name] = true
		}
		return out
	}
	have := indexes()
	if have["idx_inference_routes_request"] {
		t.Fatalf("idx_inference_routes_request still present after migrate: %v", have)
	}
	// The (request_id, attempt) uniqueness is backed either by the table
	// constraint's index or by the explicit DO-block index on legacy schemas.
	if !have["inference_routes_request_id_attempt_key"] && !have["idx_inference_routes_request_attempt_unique"] {
		t.Fatalf("unique (request_id, attempt) index missing: %v", have)
	}
	// Idempotent: nothing to drop on the next boot.
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("second migrate: %v", err)
	}
	if indexes()["idx_inference_routes_request"] {
		t.Fatal("index reappeared after the second migrate")
	}

	// A request_id-only lookup is served by the (request_id, attempt) prefix.
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SET enable_seqscan = off`); err != nil {
		t.Fatal(err)
	}
	var plan string
	if err := conn.QueryRow(ctx, `EXPLAIN (FORMAT TEXT) SELECT attempt FROM inference_routes WHERE request_id = 'probe'`).Scan(&plan); err != nil {
		t.Fatalf("explain: %v", err)
	}
	if !strings.Contains(plan, "idx_inference_routes_request_attempt_unique") && !strings.Contains(plan, "inference_routes_request_id_attempt_key") {
		t.Fatalf("request_id lookup does not use the unique prefix index: %s", plan)
	}
}
