package postgres_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pressly/goose/v3/lock"
)

// The goose files and the pg_dump schema files, relative to this test
// package.
var (
	migrationSQLDir = filepath.Join("..", "..", "..", "store", "postgres", "schema", "migrations")
	// checkedInSchemaFile is the pg_dump of the schema the migrations build.
	checkedInSchemaFile = filepath.Join("..", "..", "..", "store", "postgres", "schema", "schema.sql")
	// preGooseSchemaFile is the pg_dump of the schema the pre-goose boot
	// loop built: the state of every database before its first goose run.
	preGooseSchemaFile = filepath.Join("testdata", "schema_pre_goose.sql")
)

// lastPreGooseVersion is the last version that only replays the pre-goose
// boot.
const lastPreGooseVersion = 5

// gooseVersionTable is the table in which the store records applied goose
// versions. The operations runbook queries it by this name.
const gooseVersionTable = "goose_db_version"

// baselineStatements returns the statement blocks of the goose baseline in
// file order.
func baselineStatements(t testing.TB) []string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(migrationSQLDir, "00001_baseline.sql"))
	if err != nil {
		t.Fatalf("read baseline: %v", err)
	}
	var out []string
	for _, block := range strings.Split(string(b), "-- +goose StatementBegin\n")[1:] {
		end := strings.Index(block, "\n-- +goose StatementEnd")
		if end < 0 {
			t.Fatalf("baseline block without StatementEnd: %.80s", block)
		}
		out = append(out, block[:end])
	}
	return out
}

// baselineStatement returns the one baseline statement that contains text.
func baselineStatement(t testing.TB, text string) string {
	t.Helper()
	var found []string
	for _, stmt := range baselineStatements(t) {
		if strings.Contains(stmt, text) {
			found = append(found, stmt)
		}
	}
	if len(found) != 1 {
		t.Fatalf("%d baseline statements contain %q, want 1", len(found), text)
	}
	return found[0]
}

// forgetMigrationVersions drops the goose version table, so the next
// migration run treats the database as one a pre-goose binary last migrated
// and applies every version again. It holds the goose advisory lock, so a
// migration run of another test package on the shared database is not cut in
// half.
func forgetMigrationVersions(t testing.TB, s *postgresFixture) {
	t.Helper()
	ctx := context.Background()
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire connection: %v", err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", lock.DefaultLockID); err != nil {
		t.Fatalf("take goose lock: %v", err)
	}
	defer func() { _, _ = conn.Exec(ctx, "SELECT pg_advisory_unlock($1)", lock.DefaultLockID) }()
	if _, err := conn.Exec(ctx, "DROP TABLE IF EXISTS "+gooseVersionTable); err != nil {
		t.Fatalf("drop %s: %v", gooseVersionTable, err)
	}
}

// replayMigrations reopens the store on the database of s after it forgets
// the goose versions, so every migration runs again, as on the first goose
// boot of a database that a pre-goose binary migrated.
func replayMigrations(t testing.TB, s *postgresFixture) {
	t.Helper()
	forgetMigrationVersions(t, s)
	if err := s.reopen(context.Background()); err != nil {
		t.Fatalf("replay migrations: %v", err)
	}
}

// loadSchemaFile applies a pg_dump schema file to the database at pool. The
// session settings at the top of the dump are skipped: some name settings
// older servers do not have, and the empty search_path would stay on the
// pooled connection.
func loadSchemaFile(t testing.TB, pool *pgxpool.Pool, path string) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read schema file: %v", err)
	}
	var kept []string
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "SET ") || strings.HasPrefix(line, "SELECT pg_catalog.set_config(") {
			continue
		}
		kept = append(kept, line)
	}
	if _, err := pool.Exec(context.Background(), strings.Join(kept, "\n")); err != nil {
		t.Fatalf("load schema file: %v", err)
	}
}

// schemaSnapshotSQL describes every object in the current schema as sorted
// text lines: relations, columns in order, constraints, indexes, triggers,
// functions and sequences. Privileges and comments are left out, as in the
// checked-in dump. The goose version table is left out.
const schemaSnapshotSQL = `
WITH ns AS (SELECT oid FROM pg_namespace WHERE nspname = current_schema()),
rel AS (SELECT c.* FROM pg_class c WHERE c.relnamespace = (SELECT oid FROM ns)
        AND c.relname NOT LIKE 'goose_db_version%')
SELECT line FROM (
  SELECT format('relation %s kind=%s options=%s', relname, relkind, COALESCE(reloptions::text, '')) AS line
    FROM rel
  UNION ALL
  SELECT format('column %s.%s position=%s type=%s not_null=%s default=%s identity=%s generated=%s',
         c.relname, a.attname,
         row_number() OVER (PARTITION BY c.oid ORDER BY a.attnum),
         format_type(a.atttypid, a.atttypmod), a.attnotnull,
         COALESCE(pg_get_expr(d.adbin, d.adrelid), ''), a.attidentity, a.attgenerated)
    FROM rel c
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE c.relkind IN ('r', 'p', 'v', 'm')
  UNION ALL
  SELECT format('constraint %s %s %s', c.relname, con.conname, pg_get_constraintdef(con.oid))
    FROM pg_constraint con JOIN rel c ON c.oid = con.conrelid
  UNION ALL
  SELECT format('index %s valid=%s', pg_get_indexdef(i.indexrelid), i.indisvalid)
    FROM pg_index i JOIN rel c ON c.oid = i.indexrelid
  UNION ALL
  SELECT 'trigger ' || pg_get_triggerdef(tg.oid)
    FROM pg_trigger tg JOIN rel c ON c.oid = tg.tgrelid
   WHERE NOT tg.tgisinternal
  UNION ALL
  SELECT 'function ' || pg_get_functiondef(p.oid)
    FROM pg_proc p WHERE p.pronamespace = (SELECT oid FROM ns)
  UNION ALL
  SELECT format('sequence %s type=%s start=%s increment=%s min=%s max=%s cache=%s cycle=%s',
         c.relname, format_type(s.seqtypid, NULL), s.seqstart, s.seqincrement,
         s.seqmin, s.seqmax, s.seqcache, s.seqcycle)
    FROM pg_sequence s JOIN rel c ON c.oid = s.seqrelid
  UNION ALL
  SELECT format('sequence-owner %s %s.%s', seq.relname, tab.relname, a.attname)
    FROM pg_depend dep
    JOIN rel seq ON seq.oid = dep.objid AND seq.relkind = 'S'
    JOIN pg_class tab ON tab.oid = dep.refobjid
    JOIN pg_attribute a ON a.attrelid = dep.refobjid AND a.attnum = dep.refobjsubid
   WHERE dep.classid = 'pg_class'::regclass AND dep.deptype IN ('a', 'i')
) objects
ORDER BY line`

func schemaSnapshot(t testing.TB, pool *pgxpool.Pool) []string {
	t.Helper()
	return queryLines(t, pool, schemaSnapshotSQL)
}

// queryLines returns the single text column of every row that query returns.
func queryLines(t testing.TB, pool *pgxpool.Pool, query string) []string {
	t.Helper()
	rows, err := pool.Query(context.Background(), query)
	if err != nil {
		t.Fatalf("query lines: %v", err)
	}
	defer rows.Close()
	var lines []string
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatalf("scan line: %v", err)
		}
		lines = append(lines, line)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("read lines: %v", err)
	}
	return lines
}

// assertSameLines fails with the lines only one snapshot has.
func assertSameLines(t testing.TB, wantName string, want []string, gotName string, got []string) {
	t.Helper()
	count := map[string]int{}
	for _, line := range want {
		count[line]++
	}
	for _, line := range got {
		count[line]--
	}
	var diff []string
	for line, n := range count {
		switch {
		case n > 0:
			diff = append(diff, "only in "+wantName+": "+line)
		case n < 0:
			diff = append(diff, "only in "+gotName+": "+line)
		}
	}
	if len(diff) > 0 {
		t.Fatalf("%s and %s differ (%d lines):\n%s", wantName, gotName, len(diff), strings.Join(diff, "\n"))
	}
	if len(want) == 0 {
		t.Fatalf("%s snapshot is empty", wantName)
	}
}

func openTestPool(t testing.TB, databaseURL string) *pgxpool.Pool {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatalf("open pool: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}
