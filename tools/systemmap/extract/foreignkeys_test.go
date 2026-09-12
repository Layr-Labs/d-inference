package extract

import (
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

// TestForeignKeys covers the forms one fragment of DDL can declare a reference in.
// The fixture proves the three that a schema is normally written in; this covers the
// ones that make a *reader* of the regex wrong — several keys in one statement, a
// clause that lends its name to the wrong key, a reference with no column list, and
// prose that looks like one.
func TestForeignKeys(t *testing.T) {
	type key struct {
		name             string
		columns, refCols []string
		table            string
		onDelete         string
		onUpdate         string
	}
	flat := func(fks []ir.ForeignKey) []key {
		out := make([]key, 0, len(fks))
		for _, fk := range fks {
			out = append(out, key{fk.Name, fk.Columns, fk.RefColumns, fk.Table, fk.OnDelete, fk.OnUpdate})
		}
		return out
	}

	cases := []struct {
		name string
		text string
		own  []string
		want []key
	}{{
		name: "inline column reference",
		text: "model_id UUID NOT NULL REFERENCES models(id) ON DELETE CASCADE",
		own:  []string{"model_id"},
		want: []key{{columns: []string{"model_id"}, refCols: []string{"id"},
			table: "models", onDelete: "CASCADE"}},
	}, {
		// The columns the key is *on* come from its own list and override what the
		// caller supplied, which for a table-level constraint is nothing.
		name: "table level, two columns",
		text: "CONSTRAINT usage_span_fk FOREIGN KEY (id, created_at) REFERENCES windows (id, started_at) ON UPDATE RESTRICT",
		want: []key{{name: "usage_span_fk", columns: []string{"id", "created_at"},
			refCols: []string{"id", "started_at"}, table: "windows", onUpdate: "RESTRICT"}},
	}, {
		// One statement, two keys. Each owns the text between the reference before it
		// and the one after, so neither takes the other's name, columns or action —
		// the shape that a single FindStringSubmatch reads as one key with the first
		// name and the last action.
		name: "two keys in one statement",
		text: `ALTER TABLE usage
			ADD CONSTRAINT usage_model_fk FOREIGN KEY (model_id) REFERENCES models (id) ON DELETE CASCADE,
			ADD CONSTRAINT usage_parent_fk FOREIGN KEY (parent_id) REFERENCES usage (id) ON DELETE SET NULL`,
		want: []key{
			{name: "usage_model_fk", columns: []string{"model_id"}, refCols: []string{"id"},
				table: "models", onDelete: "CASCADE"},
			{name: "usage_parent_fk", columns: []string{"parent_id"}, refCols: []string{"id"},
				table: "usage", onDelete: "SET NULL"},
		},
	}, {
		// A CHECK constraint declared before the key is nearer to it than the key's own
		// name would be if the *first* CONSTRAINT in the fragment won.
		name: "a neighbouring constraint does not lend its name",
		text: `CONSTRAINT usage_tokens_ck CHECK (tokens >= 0),
			CONSTRAINT usage_model_fk FOREIGN KEY (model_id) REFERENCES models (id)`,
		want: []key{{name: "usage_model_fk", columns: []string{"model_id"},
			refCols: []string{"id"}, table: "models"}},
	}, {
		// Postgres defaults the reference to the target's primary key, so a key with no
		// list is legal and names no referenced column. Publishing one it does not name
		// would be inventing the target's schema.
		name: "no referenced column list",
		text: "owner_id UUID REFERENCES users",
		own:  []string{"owner_id"},
		want: []key{{columns: []string{"owner_id"}, table: "users"}},
	}, {
		name: "unnamed table-level key",
		text: "FOREIGN KEY (model_id) REFERENCES models (id) ON UPDATE NO ACTION ON DELETE SET DEFAULT",
		want: []key{{columns: []string{"model_id"}, refCols: []string{"id"}, table: "models",
			onDelete: "SET DEFAULT", onUpdate: "NO ACTION"}},
	}, {
		// The schema-qualified spelling names the same table as the bare one, so both
		// have to fold to one name or the graph draws two dots for one table.
		name: "schema qualified target",
		text: "model_id UUID REFERENCES public.models (id)",
		own:  []string{"model_id"},
		want: []key{{columns: []string{"model_id"}, refCols: []string{"id"}, table: "models"}},
	}, {
		// Whitespace is allowed on both sides of the qualifying dot, so a schema-qualified
		// name spelled loosely still resolves to the table rather than to the schema. It
		// fails loudly rather than quietly — `public` declares no CREATE TABLE, so the
		// drift gate trips — but the right answer is available and the gate should not
		// have to be the thing that reports it.
		name: "schema qualified with space around the dot",
		text: `model_id UUID REFERENCES public . models (id)`,
		own:  []string{"model_id"},
		want: []key{{columns: []string{"model_id"}, refCols: []string{"id"}, table: "models"}},
	}, {
		// A value that reads like a declaration. The scan is a regex over SQL, so a
		// keyword inside a string literal is indistinguishable from one in the statement
		// unless the literal is masked — and this is the shape that would put an arrow
		// between two tables into the graph on the strength of a default value.
		name: "a reference inside a string literal is a value",
		text: `note TEXT DEFAULT 'see REFERENCES models(id)' NOT NULL`,
		own:  []string{"note"},
	}, {
		// The mask must not swallow the statement around the literal: the key after a
		// quoted keyword is still read, and it is still read correctly.
		name: "a real key after a quoted one",
		text: `note TEXT DEFAULT 'REFERENCES quotas (id)', ` +
			`CONSTRAINT usage_model_fk FOREIGN KEY (model_id) REFERENCES models (id)`,
		want: []key{{name: "usage_model_fk", columns: []string{"model_id"},
			refCols: []string{"id"}, table: "models"}},
	}, {
		// Double quotes are the other quoting rule in SQL and mean the opposite thing:
		// they spell an identifier, so what they contain is exactly what must be read.
		name: "a quoted identifier is a table",
		text: `model_id UUID REFERENCES "models" ("id")`,
		own:  []string{"model_id"},
		want: []key{{columns: []string{"model_id"}, refCols: []string{"id"}, table: "models"}},
	}, {
		// A fragment that declares no reference at all, which is almost every fragment.
		name: "no reference",
		text: "created_at TIMESTAMPTZ NOT NULL DEFAULT now()",
		own:  []string{"created_at"},
	}, {
		// A key on no columns is not a key: without the caller's column and without a
		// list of its own there is nothing to draw an arrow from, and reporting one
		// would put an edge in the graph with an empty end.
		name: "reference naming no columns",
		text: "REFERENCES models (id)",
	}}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := flat(foreignKeys(tc.text, tc.own, "store/store.go:12"))
			if len(tc.want) == 0 {
				if len(got) != 0 {
					t.Fatalf("declared %v, want no key", got)
				}
				return
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("keys = %+v, want %+v", got, tc.want)
			}
			for _, fk := range foreignKeys(tc.text, tc.own, "store/store.go:12") {
				if fk.Site != "store/store.go:12" {
					t.Errorf("key %q is cited at %q, not at the site it was read from", fk.Table, fk.Site)
				}
			}
		})
	}
}

// TestForeignKeysIgnoreComments covers the pairing of the mask with the scan. The DDL
// is read by regex rather than parsed, so a sentence mentioning a table would mint a
// relationship out of prose — an arrow between two `pg.*` nodes that no database has.
func TestForeignKeysIgnoreComments(t *testing.T) {
	text := `CREATE TABLE usage (
		id UUID PRIMARY KEY,
		-- model_id UUID REFERENCES models (id), dropped in v3
		tokens BIGINT NOT NULL, /* was REFERENCES quotas (id) */
		note TEXT DEFAULT '-- not a comment'
	)`
	masked := maskSQLComments(text)
	if len(masked) != len(text) {
		t.Fatalf("mask changed the length from %d to %d, so every citation after it shifts",
			len(text), len(masked))
	}
	if strings.Count(masked, "\n") != strings.Count(text, "\n") {
		t.Error("mask ate a newline, so the line a column is cited at moves")
	}
	if fks := foreignKeys(masked, nil, "store/store.go:1"); len(fks) != 0 {
		t.Errorf("commented-out DDL declared %+v", fks)
	}
	// The value survives: a quoted `--` is data, and blanking it would change the
	// statement the drawer shows and could swallow the rest of the table.
	if !strings.Contains(masked, "'-- not a comment'") {
		t.Errorf("mask blanked a quoted value:\n%s", masked)
	}
	// And the columns around the comments are still read, which is the difference
	// between masking the comment and dropping the line it is on.
	cols, _, _ := parseColumns(balancedBody(t, masked), func(int) string { return "store/store.go:1" })
	var names []string
	for _, c := range cols {
		names = append(names, c.Name)
	}
	if !reflect.DeepEqual(names, []string{"id", "tokens", "note"}) {
		t.Errorf("columns = %v, want the three the statement declares", names)
	}
}

// TestMaskSQLStrings pins the two properties the FK scan depends on: the mask is
// positional, so every span and every citation taken from the masked text still points
// where it did, and it hides only what a string literal contains.
func TestMaskSQLStrings(t *testing.T) {
	cases := []struct {
		name, text, want string
	}{{
		name: "a keyword inside a literal is hidden",
		text: `note TEXT DEFAULT 'REFERENCES models(id)'`,
		want: `note TEXT DEFAULT '                     '`,
	}, {
		// Doubling is how SQL escapes a quote inside a literal. It closes and reopens the
		// string, which blanks the same bytes either way — what matters is that no keyword
		// survives and no byte moves.
		name: "an escaped quote blanks the same bytes",
		text: `'a''REFERENCES b'`,
		want: `' ''            '`,
	}, {
		// Identifiers are quoted with double quotes and must survive: they are the table
		// names the scan is looking for.
		name: "double quotes are left alone",
		text: `REFERENCES "models" ("id")`,
		want: `REFERENCES "models" ("id")`,
	}, {
		// A literal running to the end of the fragment takes the rest of it. That is the
		// safe direction: a keyword inside an unterminated string is not a declaration
		// either, and the alternative is reading one out of it.
		name: "an unterminated literal takes the rest",
		text: `note TEXT DEFAULT 'REFERENCES models`,
		want: `note TEXT DEFAULT '                 `,
	}, {
		// Newlines stay where they are, which is the whole reason the mask blanks in place
		// instead of cutting: a column read out of the masked text is cited by line.
		name: "newlines survive",
		text: "note TEXT DEFAULT 'one\ntwo',\n tokens BIGINT",
		want: "note TEXT DEFAULT '   \n   ',\n tokens BIGINT",
	}}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := maskSQLStrings(tc.text)
			if got != tc.want {
				t.Errorf("mask =\n%q\nwant\n%q", got, tc.want)
			}
			if len(got) != len(tc.text) {
				t.Errorf("mask changed the length from %d to %d, so every citation after it shifts",
					len(tc.text), len(got))
			}
			if strings.Count(got, "\n") != strings.Count(tc.text, "\n") {
				t.Error("mask ate a newline, so the line a reference is cited at moves")
			}
		})
	}
}

func balancedBody(t *testing.T, text string) string {
	t.Helper()
	open := strings.Index(text, "(")
	if open < 0 {
		t.Fatal("no column list in the statement")
	}
	body, _ := balanced(text, open)
	return body
}
