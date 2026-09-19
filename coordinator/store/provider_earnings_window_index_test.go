package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

// TestProviderEarningsWindowIndex_BootSafe: startup leaves a valid BRIN index
// on provider_earnings(created_at) and pins the table's analyze cadence, both
// re-entrant across a restart, and the planner can use the index for the
// created_at >= $1 predicate the windowed aggregates issue.
func TestProviderEarningsWindowIndex_BootSafe(t *testing.T) {
	s := testPostgresStore(t) // t.Skip()s when DATABASE_URL is unset
	ctx := context.Background()

	assertWindowIndex := func(when string) {
		t.Helper()
		var valid bool
		var am string
		if err := s.pool.QueryRow(ctx, `
			SELECT COALESCE(i.indisvalid AND i.indisready, false), am.amname
			FROM pg_class c
			JOIN pg_index i ON i.indexrelid = c.oid
			JOIN pg_am am ON am.oid = c.relam
			WHERE c.relname = $1`, providerEarningsWindowIndex).Scan(&valid, &am); err != nil {
			t.Fatalf("%s: inspect %s: %v", when, providerEarningsWindowIndex, err)
		}
		if !valid || am != "brin" {
			t.Fatalf("%s: %s valid=%v am=%q, want a valid brin index", when, providerEarningsWindowIndex, valid, am)
		}
		var opts []string
		if err := s.pool.QueryRow(ctx, `SELECT COALESCE(reloptions, '{}') FROM pg_class WHERE oid = 'provider_earnings'::regclass`).Scan(&opts); err != nil {
			t.Fatalf("%s: read reloptions: %v", when, err)
		}
		want := "autovacuum_analyze_scale_factor=" + providerEarningsAnalyzeScaleFactor
		if indexOf(opts, want) < 0 {
			t.Fatalf("%s: provider_earnings reloptions = %v, want %s", when, opts, want)
		}
	}
	assertWindowIndex("after startup")

	// A restart re-runs migrate(): the valid-index fast path and the
	// already-set reloption make both steps no-ops rather than errors.
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("re-running migrate (restart): %v", err)
	}
	assertWindowIndex("after re-running migrate")

	// The index must be applicable to the windowed aggregates' predicate. The
	// test table is tiny, so disable seq scans to make the planner show it.
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID: uniqueID("acct"), ProviderID: "p", ProviderKey: uniqueID("pk"), JobID: uniqueID("job"),
		Model: "m", AmountMicroUSD: 1, PromptTokens: 1, CompletionTokens: 1, CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("record earning: %v", err)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, "SET LOCAL enable_seqscan = off"); err != nil {
		t.Fatal(err)
	}
	rows, err := tx.Query(ctx, `EXPLAIN SELECT count(*) FROM provider_earnings WHERE created_at >= $1`, time.Now().Add(-24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	var plan []string
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		plan = append(plan, line)
	}
	rows.Close()
	if joined := strings.Join(plan, "\n"); !strings.Contains(joined, providerEarningsWindowIndex) {
		t.Fatalf("planner does not use %s for a created_at window:\n%s", providerEarningsWindowIndex, joined)
	}
}
