package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

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
