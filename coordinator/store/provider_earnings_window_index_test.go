package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

// TestProviderEarningsWindowIndex_BootSafe: startup leaves a valid BRIN index
// on provider_earnings(created_at) and pins the table's analyze cadence, both
// re-entrant across a restart, and the index is a working BRIN index on
// created_at (the column the windowed aggregates filter on).
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

	// The index is on created_at and is a working BRIN index: summarising a
	// freshly inserted row's block range must succeed. (Which index the planner
	// picks is scale-dependent and is not asserted here; on a table this small
	// a bitmap scan over any btree is as cheap.)
	var def string
	if err := s.pool.QueryRow(ctx, `SELECT pg_get_indexdef(to_regclass($1))`, providerEarningsWindowIndex).Scan(&def); err != nil {
		t.Fatalf("indexdef: %v", err)
	}
	if !strings.Contains(def, "USING brin (created_at)") {
		t.Fatalf("indexdef = %q, want USING brin (created_at)", def)
	}
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID: uniqueID("acct"), ProviderID: "p", ProviderKey: uniqueID("pk"), JobID: uniqueID("job"),
		Model: "m", AmountMicroUSD: 1, PromptTokens: 1, CompletionTokens: 1, CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("record earning: %v", err)
	}
	var summarized int64
	if err := s.pool.QueryRow(ctx, `SELECT brin_summarize_new_values(to_regclass($1))`, providerEarningsWindowIndex).Scan(&summarized); err != nil {
		t.Fatalf("brin_summarize_new_values: %v", err)
	}
	if summarized < 0 {
		t.Fatalf("brin_summarize_new_values = %d", summarized)
	}
}
