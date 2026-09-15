package extract

// Referential structure is derived the way the columns are: read out of the DDL
// the service issues, never transcribed. A foreign key is the one part of a schema
// that is about two tables rather than one, so it is what turns the derived table
// definitions into a graph — and it is exactly the part a hand-drawn ER diagram
// gets wrong first, because a key added in a migration is invisible in the CREATE
// that a reader is most likely to be looking at.
//
// Three forms declare the same thing, and all three are read here: an inline
// column-level `REFERENCES`, a table-level `FOREIGN KEY (...) REFERENCES ...`, and
// an `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY ...`. The reference clause is
// the same in each, which is why the columns being referenced *from* are the only
// thing the caller has to supply.

import (
	"regexp"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

var (
	reFKReferences = regexp.MustCompile(`(?is)\breferences\s+("?[a-z_][a-z0-9_$]*"?(?:\s*\.\s*"?[a-z_][a-z0-9_$]*"?)?)\s*(?:\(([^)]*)\))?`)
	reFKColumns    = regexp.MustCompile(`(?is)\bforeign\s+key\s*\(([^)]*)\)`)
	reFKAction     = regexp.MustCompile(`(?is)\bon\s+(delete|update)\s+(no\s+action|restrict|cascade|set\s+null|set\s+default)`)
	reFKName       = regexp.MustCompile(`(?is)\bconstraint\s+("?[a-z_][a-z0-9_$]*"?)\s`)
)

// foreignKeys reads every referential constraint one fragment of DDL declares. own
// is the column the fragment already named, used when the fragment is a column
// definition and so names no columns of its own; a table-level or ALTER form
// overrides it with the columns in its own `FOREIGN KEY (...)` list. The result is
// empty for the common case of a fragment that declares no reference at all.
//
// One fragment can declare several, because one statement can:
// `ALTER TABLE t ADD CONSTRAINT a FOREIGN KEY (x) REFERENCES u(id),
// ADD CONSTRAINT b FOREIGN KEY (y) REFERENCES v(id)` is legal and is two keys. So
// each `REFERENCES` owns the span of text between the previous one and the next, and
// every clause it takes is read out of that span alone: the name and column list
// from the part before it — the *nearest* ones, so that a `CHECK` constraint
// declared alongside cannot lend its name to the key — and the referential actions
// from the part after it.
func foreignKeys(text string, own []string, site string) []ir.ForeignKey {
	// A quoted string is a value, not a declaration: `note text DEFAULT 'see
	// REFERENCES models(id)'` declares no key, and reading one out of it would draw an
	// edge between two tables out of a sentence — the same mistake maskSQLComments
	// exists to prevent, one clause over. The mask keeps every byte and every newline
	// in place, so the spans below still line up with the text and the citation still
	// points at the line the reference is on. Double quotes are left alone: they are
	// how SQL spells an identifier, and `REFERENCES "models"` is a real key.
	text = maskSQLStrings(text)
	all := reFKReferences.FindAllStringSubmatchIndex(text, -1)
	var out []ir.ForeignKey
	for i, m := range all {
		// The span this reference owns: from the end of the previous reference to the
		// start of the next.
		from := 0
		if i > 0 {
			from = all[i-1][1]
		}
		to := len(text)
		if i+1 < len(all) {
			to = all[i+1][0]
		}
		before, after := text[from:m[0]], text[m[1]:to]
		fk := ir.ForeignKey{
			Table:   cleanIdent(strings.ToLower(collapse(text[m[2]:m[3]]))),
			Columns: own,
			Site:    site,
		}
		if fk.Table == "" {
			continue
		}
		if m[4] >= 0 {
			fk.RefColumns = identList(text[m[4]:m[5]])
		}
		if c := lastMatch(reFKColumns, before); c != nil {
			fk.Columns = identList(c[1])
		}
		if n := lastMatch(reFKName, before); n != nil {
			fk.Name = cleanIdent(strings.ToLower(n[1]))
		}
		for _, a := range reFKAction.FindAllStringSubmatch(after, -1) {
			switch strings.ToLower(a[1]) {
			case "delete":
				fk.OnDelete = strings.ToUpper(collapse(a[2]))
			case "update":
				fk.OnUpdate = strings.ToUpper(collapse(a[2]))
			}
		}
		if len(fk.Columns) == 0 {
			continue
		}
		out = append(out, fk)
	}
	return out
}

// lastMatch is the match nearest the end of the text, which for the clauses that
// precede a `REFERENCES` is the one that belongs to it.
func lastMatch(re *regexp.Regexp, text string) []string {
	all := re.FindAllStringSubmatch(text, -1)
	if len(all) == 0 {
		return nil
	}
	return all[len(all)-1]
}

// identList reads a parenthesised column list.
func identList(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if name := cleanIdent(strings.ToLower(strings.TrimSpace(part))); name != "" {
			out = append(out, name)
		}
	}
	return out
}

// addForeignKey records a key once, keyed on what the key *is* — which columns of
// this table point at which other table — rather than on where it was written.
//
// The same constraint is reachable from several places on purpose. A `DO $$ ... $$`
// block holding an ALTER is matched as both the block's literal and the statement
// inside it. More often, a schema that has to work on a fresh database and on an old
// one declares the key twice: inline in `CREATE TABLE IF NOT EXISTS` and again as a
// defensive `ALTER TABLE ... ADD CONSTRAINT`. And `ALTER TABLE t ADD COLUMN x int,
// ADD CONSTRAINT fk FOREIGN KEY (x) REFERENCES u(id)` is read by both the ADD COLUMN
// pass and the ALTER pass, at two different sites. All of those are one relationship,
// and drawing one arrow per declaration would multiply it.
//
// The first declaration read wins — the DDL passes run in a fixed order over a fixed
// order of files, so which one that is, is deterministic — and the surviving key is
// cited at that declaration. Nothing else about the relationship differs between
// them; if a second declaration disagreed about the referential action, the schema
// itself would be ambiguous.
func addForeignKey(t *ir.Table, fk ir.ForeignKey) {
	for _, have := range t.ForeignKeys {
		if have.Table == fk.Table &&
			strings.Join(have.Columns, ",") == strings.Join(fk.Columns, ",") {
			return
		}
	}
	t.ForeignKeys = append(t.ForeignKeys, fk)
}
