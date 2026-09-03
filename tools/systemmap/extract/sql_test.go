package extract

import (
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"
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
	}, {
		// The locking mask has to look at what follows the words it blanks. Statement
		// text is scanned after normalization, which lower-cases it and flattens the
		// newline that ended this comment, so a comment whose last word is "for" sits
		// directly in front of a real UPDATE. Blanking it dropped the write entirely —
		// the map losing a table with every count still balanced.
		name: "a comment ending in for does not blank the UPDATE after it",
		sql:  "CREATE TABLE IF NOT EXISTS models (id text);\n-- rows queued for\nUPDATE usage SET tokens = 0",
		want: []TableAccess{{"models", "W"}, {"usage", "W"}},
	}, {
		name: "the lock itself is still masked, however it continues",
		sql:  `SELECT id FROM models WHERE id = $1 FOR NO KEY UPDATE OF models SKIP LOCKED`,
		want: []TableAccess{{"models", "R"}},
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

// TestMaskKeywordCallsStaysAligned pins the one property the mask depends on: the
// case-folded copy it searches has to line up byte for byte with the text it
// blanks. strings.ToLower does not guarantee that — U+212A KELVIN SIGN is three
// bytes and folds to one — so a single such rune in a statement would shift every
// offset after it and blank the wrong bytes, quietly turning the keyword-call mask
// off for the rest of the string.
func TestMaskKeywordCallsStaysAligned(t *testing.T) {
	// The Kelvin sign sits before the call, so a length-changing fold would move
	// the argument list out from under the offsets the mask writes at.
	sql := `SELECT x FROM models WHERE n = 'K' AND y = EXTRACT(EPOCH FROM created_at)`
	got := string(maskKeywordCalls([]byte(sql)))
	if len(got) != len(sql) {
		t.Fatalf("mask changed the length of the text: %d, want %d", len(got), len(sql))
	}
	if strings.Contains(strings.ToLower(got), "epoch") {
		t.Errorf("keyword-call arguments survived the mask: %q", got)
	}
	if !strings.Contains(got, "FROM models") {
		t.Errorf("mask blanked text outside the call: %q", got)
	}
}

// TestEllipsisKeepsRunes covers the quoting a finding does. Cutting a long
// statement at a fixed byte offset can land in the middle of a rune, which would
// put a replacement character in the report — the one place a reader looks to
// find out which text the extractor could not read.
func TestEllipsisKeepsRunes(t *testing.T) {
	// The em dash is three bytes and is placed so that the 57-byte cut lands on its
	// second byte, which is the only offset that can produce a broken rune.
	long := "SELECT id FROM models WHERE note = 'wide need— wider — widest'"
	// An edit to that literal must not move the cut back onto a boundary, which
	// would leave the test passing while proving nothing.
	if utf8.RuneStart(long[57]) {
		t.Fatal("byte 57 of the fixture text is a rune start, so this test cannot fail")
	}
	got := ellipsis(long)
	if !strings.HasSuffix(got, "...") {
		t.Fatalf("long text was not shortened: %q", got)
	}
	if !utf8.ValidString(got) {
		t.Errorf("shortened text is not valid UTF-8: %q", got)
	}
	if short := "SELECT id FROM models"; ellipsis(short) != short {
		t.Errorf("ellipsis(%q) = %q, want it unchanged", short, ellipsis(short))
	}
}
