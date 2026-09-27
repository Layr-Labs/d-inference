package store

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

type restoreIndexPlan struct {
	NodeType  string             `json:"Node Type"`
	IndexName string             `json:"Index Name"`
	Plans     []restoreIndexPlan `json:"Plans"`
}

func TestPostgresRestoreIndexes(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, "SET LOCAL enable_seqscan=off"); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, "SET LOCAL enable_bitmapscan=off"); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, column string }{
		{"idx_providers_restore_serial", "serial_number"},
		{"idx_providers_restore_se_key", "se_public_key"},
	} {
		// Validate the real migrated index independently of PostgreSQL's cost-based
		// choice among competing providers indexes (CI can prefer the older serial
		// index on its nearly empty fixture without invalidating this index).
		var valid, ready, unique, correctTable bool
		var keyCount, attributeCount int
		var method, predicate, definition string
		var columns []string
		var options []int16
		err := tx.QueryRow(ctx, `SELECT i.indisvalid,i.indisready,i.indisunique,
   i.indrelid='providers'::regclass,i.indnkeyatts,i.indnatts,am.amname,
   ARRAY(SELECT a.attname::text FROM unnest(i.indkey::smallint[]) WITH ORDINALITY k(attnum,pos)
    JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum ORDER BY k.pos),
   i.indoption::smallint[],pg_get_expr(i.indpred,i.indrelid),pg_get_indexdef(i.indexrelid)
   FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_am am ON am.oid=c.relam
   WHERE i.indexrelid=to_regclass(format('%I.%I',current_schema(),$1::text))`, tc.name).Scan(
			&valid, &ready, &unique, &correctTable, &keyCount, &attributeCount, &method, &columns, &options, &predicate, &definition)
		if err != nil {
			t.Fatal(err)
		}
		if !valid || !ready || unique || !correctTable || keyCount != 3 || attributeCount != 3 || method != "btree" {
			t.Fatalf("invalid restore index metadata for %s: %s", tc.name, definition)
		}
		wantColumns := []string{tc.column, "last_seen", "id"}
		wantOptions := []int16{0, 3, 3} // ASC NULLS LAST, then DESC NULLS FIRST twice
		if len(columns) != 3 || len(options) != 3 {
			t.Fatalf("unexpected key shape: %s", definition)
		}
		for i := range wantColumns {
			if columns[i] != wantColumns[i] || options[i] != wantOptions[i] {
				t.Fatalf("wrong key/order: %s", definition)
			}
		}
		if predicate != fmt.Sprintf("(%s <> ''::text)", tc.column) {
			t.Fatalf("wrong partial predicate: %s", definition)
		}

		// Clone the actual index method/options/predicate onto a disposable table
		// with no competing indexes. This checks that its exact definition can
		// satisfy the lookup/exclusion/order without a sort, not that it wins an
		// incidental cost comparison against other valid production indexes.
		table := pgx.Identifier{"restore_probe_" + tc.column}.Sanitize()
		probeName := "probe_" + tc.name
		if _, err := tx.Exec(ctx, "CREATE TEMP TABLE "+table+`(id text NOT NULL,serial_number text NOT NULL,se_public_key text NOT NULL,last_seen timestamptz NOT NULL,hardware jsonb NOT NULL) ON COMMIT DROP`); err != nil {
			t.Fatal(err)
		}
		tail := strings.Index(definition, " USING ")
		if tail < 0 {
			t.Fatalf("missing index method: %s", definition)
		}
		if _, err := tx.Exec(ctx, "CREATE INDEX "+pgx.Identifier{probeName}.Sanitize()+" ON "+table+definition[tail:]); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, "INSERT INTO "+table+` SELECT 'p'||g,'s','s',NOW()+g*INTERVAL '1 second','{}'::jsonb FROM generate_series(1,20) g`); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, "INSERT INTO "+table+` VALUES('current','s','s',NOW()+INTERVAL '1 hour','{}')`); err != nil {
			t.Fatal(err)
		}
		query := "SELECT id,hardware FROM " + table + " WHERE " + tc.column + `='s' AND ` + tc.column + `<>'' AND id<>ALL(ARRAY['current']::text[]) ORDER BY last_seen DESC,id DESC LIMIT 1`
		var raw []byte
		if err := tx.QueryRow(ctx, "EXPLAIN (FORMAT JSON) "+query).Scan(&raw); err != nil {
			t.Fatal(err)
		}
		var plan []struct{ Plan restoreIndexPlan }
		if err := json.Unmarshal(raw, &plan); err != nil || len(plan) != 1 {
			t.Fatalf("bad plan: %s %v", raw, err)
		}
		found := false
		var walk func(restoreIndexPlan)
		walk = func(node restoreIndexPlan) {
			if node.NodeType == "Sort" || node.NodeType == "Incremental Sort" {
				t.Fatalf("restore index cannot provide order: %s", raw)
			}
			if node.IndexName == probeName {
				found = true
			}
			for _, child := range node.Plans {
				walk(child)
			}
		}
		walk(plan[0].Plan)
		if !found {
			t.Fatalf("restore index is not applicable: %s", raw)
		}
		var id string
		var hardware []byte
		if err := tx.QueryRow(ctx, query).Scan(&id, &hardware); err != nil || id != "p20" {
			t.Fatalf("wrong newest prior row: %s %v", id, err)
		}
	}
}
