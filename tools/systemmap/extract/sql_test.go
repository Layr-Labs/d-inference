package extract

import (
	"reflect"
	"testing"
)

// TestIsSQLStatements pins the statement shapes the coordinator actually issues.
func TestIsSQLStatements(t *testing.T) {
	for _, s := range []string{
		`SELECT id, name FROM models ORDER BY name`,
		`select count(*) from providers where trust = $1`,
		"INSERT INTO usage (id, tokens)\n\tVALUES ($1, $2)",
		`UPDATE models SET name = $1 WHERE id = $2`,
		`DELETE FROM usage WHERE id = $1`,
		`WITH recent AS (SELECT id FROM usage) SELECT id FROM recent`,
		`CREATE TABLE IF NOT EXISTS models (id text PRIMARY KEY)`,
		`CREATE UNIQUE INDEX models_name_key ON models (name)`,
		`ALTER TABLE models ADD COLUMN family text`,
		`DROP TABLE IF EXISTS legacy_models`,
		`TRUNCATE TABLE usage`,
		`SELECT (SELECT 1)`,
	} {
		if !IsSQL(s) {
			t.Errorf("IsSQL(%q) = false, want true", s)
		}
	}
}

// TestIsSQLProse is the regression that matters most: a leading SQL verb is not a
// statement. Before the grammar table, English like "update capabilities …"
// parsed as a statement and invented a table named after the next word.
func TestIsSQLProse(t *testing.T) {
	for _, s := range []string{
		"update capabilities to include the new model",
		"select the cheapest provider that can serve the request",
		"delete the stale reservation and retry",
		"with a warm pool the first token arrives sooner",
		"provider disconnected before content, retrying elsewhere",
		"insert",
		"SELECT",
	} {
		if IsSQL(s) {
			t.Errorf("IsSQL(%q) = true, want false", s)
		}
	}
}

func TestTables(t *testing.T) {
	cases := []struct {
		name string
		sql  string
		want []TableAccess
	}{{
		name: "select reads",
		sql:  `SELECT id, name FROM models ORDER BY name`,
		want: []TableAccess{{"models", "R"}},
	}, {
		name: "insert target is a write, its select source a read",
		sql:  `INSERT INTO usage (id, tokens) SELECT id, $2 FROM models WHERE id = $1`,
		want: []TableAccess{{"models", "R"}, {"usage", "W"}},
	}, {
		name: "extract(... FROM ...) does not name a table",
		sql:  `SELECT extract(epoch FROM now() - created_at) FROM usage WHERE id = $1`,
		want: []TableAccess{{"usage", "R"}},
	}, {
		name: "CTE names are not tables",
		sql:  `WITH recent AS (SELECT id FROM usage) SELECT r.id FROM recent r JOIN models m ON m.id = r.id`,
		want: []TableAccess{{"models", "R"}, {"usage", "R"}},
	}, {
		name: "update writes, its FROM reads",
		sql:  `UPDATE usage SET tokens = tokens + 1 FROM models WHERE models.id = usage.id`,
		want: []TableAccess{{"models", "R"}, {"usage", "W"}},
	}, {
		name: "upsert clause is one write",
		sql:  `INSERT INTO usage (id) VALUES ($1) ON CONFLICT (id) DO UPDATE SET tokens = 0`,
		want: []TableAccess{{"usage", "W"}},
	}, {
		name: "schema qualifier and quoting are stripped",
		sql:  `SELECT 1 FROM public."usage" WHERE id = $1`,
		want: []TableAccess{{"usage", "R"}},
	}, {
		name: "read and write of the same table is RW",
		sql:  `UPDATE usage SET tokens = 0 WHERE id IN (SELECT id FROM usage LIMIT 10)`,
		want: []TableAccess{{"usage", "RW"}},
	}}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Tables(tc.sql)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("Tables(%q)\n got %v\nwant %v", tc.sql, got, tc.want)
			}
		})
	}
}
