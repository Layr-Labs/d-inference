package extract

// Table definitions are derived, not transcribed. The coordinator ships its DDL
// as string literals in Go source, so a table's real shape is the CREATE TABLE
// that declared it plus every `ALTER TABLE ... ADD COLUMN` migration that grew it
// afterwards — which is exactly why a hand-written schema doc goes stale: the
// columns added in migration statements are invisible in the original CREATE.
// Every column and every statement carries its own file:line, so the reader can
// check the claim against source.

import (
	"go/ast"
	"go/token"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

var (
	// Matched against source text, case-insensitively: the DDL is written in
	// upper case and the citation must point at the real line.
	reDDLCreate = regexp.MustCompile(`(?is)create\s+(?:unlogged\s+|temp\s+|temporary\s+)?table\s+(?:if\s+not\s+exists\s+)?("?[a-z_][a-z0-9_$]*"?(?:\.\s*"?[a-z_][a-z0-9_$]*"?)?)\s*\(`)
	reDDLAddCol = regexp.MustCompile(`(?is)alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?("?[a-z_][a-z0-9_$]*"?(?:\.\s*"?[a-z_][a-z0-9_$]*"?)?)\s+add\s+column\s+(?:if\s+not\s+exists\s+)?("?[a-z_][a-z0-9_$]*"?)\s+([^;]*?)\s*(?:;|$)`)
	reDDLAlter  = regexp.MustCompile(`(?is)alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?("?[a-z_][a-z0-9_$]*"?(?:\.\s*"?[a-z_][a-z0-9_$]*"?)?)\s`)
	reDDLIndex  = regexp.MustCompile(`(?is)create\s+(?:unique\s+)?index\s+(?:concurrently\s+)?(?:if\s+not\s+exists\s+)?[a-z_][a-z0-9_$]*\s+on\s+(?:only\s+)?("?[a-z_][a-z0-9_$]*"?(?:\.\s*"?[a-z_][a-z0-9_$]*"?)?)`)

	// Words that begin a table-level constraint rather than a column.
	ddlConstraintHeads = map[string]bool{
		"primary": true, "unique": true, "foreign": true, "constraint": true,
		"check": true, "exclude": true, "like": true,
	}
	// Second and later words of a multi-word column type.
	ddlTypeTail = map[string]bool{
		"precision": true, "varying": true, "with": true, "without": true,
		"time": true, "zone": true,
	}
)

// SchemaDefinitions derives every table the analyzed source declares. The result
// is memoized: it is asked for once to validate query table names and again to
// publish the definitions.
func (p *Program) SchemaDefinitions() map[string]*ir.Table {
	if p.schema != nil {
		return p.schema
	}
	out := map[string]*ir.Table{}
	p.schema = out
	table := func(name string) *ir.Table {
		name = cleanIdent(strings.ToLower(name))
		if name == "" {
			return nil
		}
		if t, ok := out[name]; ok {
			return t
		}
		t := &ir.Table{Name: name}
		out[name] = t
		return t
	}
	for _, path := range p.order {
		for _, file := range p.pkgs[path].Syntax {
			ast.Inspect(file, func(n ast.Node) bool {
				lit, ok := n.(*ast.BasicLit)
				if !ok {
					return true
				}
				text, ok := stringLit(lit)
				if !ok {
					return true
				}
				p.readDDL(text, lit.Pos(), table)
				return true
			})
		}
	}
	for _, t := range out {
		sort.SliceStable(t.DDL, func(i, j int) bool { return siteLess(t.DDL[i].Site, t.DDL[j].Site) })
		sort.SliceStable(t.ForeignKeys, func(i, j int) bool {
			if t.ForeignKeys[i].Site != t.ForeignKeys[j].Site {
				return siteLess(t.ForeignKeys[i].Site, t.ForeignKeys[j].Site)
			}
			return t.ForeignKeys[i].Table < t.ForeignKeys[j].Table
		})
		t.Columns = dedupeColumns(t.Columns)
	}
	return out
}

// dedupeColumns keeps one entry per column name. A column can be declared twice
// on purpose: once in the CREATE for new databases and once as an
// `ADD COLUMN IF NOT EXISTS` for databases created before it existed. The CREATE
// wins, because that is the declaration a reader should see.
func dedupeColumns(cols []ir.Column) []ir.Column {
	seen := map[string]bool{}
	out := cols[:0]
	for _, col := range cols {
		if col.Name == "" || seen[col.Name] {
			continue
		}
		seen[col.Name] = true
		out = append(out, col)
	}
	return out
}

// siteLess orders citations by file, then by line numerically — "postgres.go:90"
// before "postgres.go:144", which a string comparison gets backwards.
func siteLess(a, b string) bool {
	fa, la := splitSite(a)
	fb, lb := splitSite(b)
	if fa != fb {
		return fa < fb
	}
	return la < lb
}

func splitSite(site string) (string, int) {
	i := strings.LastIndex(site, ":")
	if i < 0 {
		return site, 0
	}
	line, _ := strconv.Atoi(site[i+1:])
	return site[:i], line
}

// SchemaTables is the set of declared table names, so a table named in a query
// can be validated instead of trusted. A typo'd or dynamically built name shows
// up as drift.
func (p *Program) SchemaTables() map[string]bool {
	out := map[string]bool{}
	for name := range p.SchemaDefinitions() {
		out[name] = true
	}
	return out
}

// readDDL records whatever DDL one string literal contains. A literal can hold
// more than one statement (the `DO $$ ... $$` migration blocks wrap an ALTER), so
// every form is searched independently rather than switching on the leading verb.
func (p *Program) readDDL(text string, pos token.Pos, table func(string) *ir.Table) {
	// Scanned with comments blanked and quoted from the original, at the same
	// indices: a sentence must not declare a column, a constraint or a foreign key,
	// and a reader still sees the statement as it is written. See maskSQLComments.
	raw := text
	text = maskSQLComments(text)
	site := func(idx int) string { return p.siteIn(pos, text, idx) }
	add := func(t *ir.Table, stmt ir.Statement) {
		for _, have := range t.DDL {
			if have.Site == stmt.Site && have.Kind == stmt.Kind {
				return
			}
		}
		t.DDL = append(t.DDL, stmt)
	}

	for _, m := range reDDLCreate.FindAllStringSubmatchIndex(text, -1) {
		t := table(text[m[2]:m[3]])
		if t == nil {
			continue
		}
		open := m[1] - 1 // the '(' the match ends on
		body, end := balanced(text, open)
		stmt := dedent(strings.TrimSpace(raw[m[0]:end]))
		add(t, ir.Statement{Kind: "create", SQL: stmt, Site: site(m[0])})
		// Prepended, not assigned: an ALTER for this table may have been found
		// first, and the declared columns still belong at the top.
		cols, cons, fks := parseColumns(body, func(idx int) string { return site(open + 1 + idx) })
		t.Columns = append(cols, t.Columns...)
		t.Constraints = append(cons, t.Constraints...)
		for _, fk := range fks {
			addForeignKey(t, fk)
		}
	}
	for _, m := range reDDLAddCol.FindAllStringSubmatchIndex(text, -1) {
		t := table(text[m[2]:m[3]])
		if t == nil {
			continue
		}
		col := ir.Column{
			Name:      cleanIdent(strings.ToLower(text[m[4]:m[5]])),
			Migration: true,
			Site:      site(m[4]),
		}
		def := strings.TrimSpace(text[m[6]:m[7]])
		col.Type, col.Extra = splitType(def)
		t.Columns = append(t.Columns, col)
		for _, fk := range foreignKeys(def, []string{col.Name}, site(m[4])) {
			addForeignKey(t, fk)
		}
	}
	for _, m := range reDDLAlter.FindAllStringSubmatchIndex(text, -1) {
		if t := table(text[m[2]:m[3]]); t != nil {
			// The statement, not the literal: one `DO $$ ... $$` block can hold
			// several ALTERs, and quoting the whole block once per match would
			// publish the same 700 characters repeatedly.
			start, stop := statementSpan(text, m[0])
			add(t, ir.Statement{Kind: "alter", SQL: dedent(strings.TrimSpace(raw[start:stop])), Site: site(m[0])})
			// Read from the masked statement, quoted from the raw one: the key is a
			// declaration and a comment beside it is not.
			for _, fk := range foreignKeys(text[start:stop], nil, site(m[0])) {
				addForeignKey(t, fk)
			}
		}
	}
	for _, m := range reDDLIndex.FindAllStringSubmatchIndex(text, -1) {
		if t := table(text[m[2]:m[3]]); t != nil {
			start, stop := statementSpan(text, m[0])
			add(t, ir.Statement{Kind: "index", SQL: dedent(strings.TrimSpace(raw[start:stop])), Site: site(m[0])})
		}
	}
}

// siteIn cites a position inside a string literal. Raw string literals — the form
// all of the schema is written in — hold their newlines verbatim, so counting them
// is the line offset from the literal's own line.
func (p *Program) siteIn(pos token.Pos, text string, idx int) string {
	pt := p.Fset.Position(pos)
	rel := strings.TrimPrefix(strings.TrimPrefix(pt.Filename, p.Root), "/")
	line := pt.Line
	if idx > 0 && idx <= len(text) {
		line += strings.Count(text[:idx], "\n")
	}
	return rel + ":" + strconv.Itoa(line)
}
