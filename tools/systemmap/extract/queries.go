package extract

import (
	"fmt"
	"go/ast"
	"go/token"
	"go/types"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

// The readable-statement checks.
//
// Every table edge in the map comes from statement text: the walker classifies a
// string literal or a folded constant expression, and `Tables` reads the table
// names out of it. That makes unreadable text a uniquely quiet failure. An
// unrecognized table is reported. A field with no node is reported. But text the
// extractor cannot read simply yields nothing, and nothing is exactly what a
// clean report looks like — the route is published as touching fewer tables than
// it does, or writing a table it also reads.
//
// Two things have to hold, because each covers what the other cannot see.
//
//  1. A body that hands the driver a statement must contain that statement. This
//     catches the case where no readable text exists at all: the whole statement
//     came from a parameter, a `strings.Builder`, or a variable assembled
//     elsewhere.
//  2. Wherever text names a table, the name must be readable and the text around
//     it must be a statement. This catches the case the count cannot: a readable
//     base statement plus a fragment — `q += " UNION SELECT id FROM usage"` — or
//     a table spliced in at run time — `fmt.Sprintf("... FROM %s", t)`. Both
//     leave the count satisfied and a table missing.

// isQueryCall reports whether a call hands a statement to the database driver.
// The receiver's type decides it, not the method name: `Query` and `Exec` are
// common enough elsewhere in the tree that a name match alone would fire on
// store wrappers and HTTP clients.
func (f *fnWalk) isQueryCall(sel *ast.SelectorExpr) bool {
	selection := f.info.Selections[sel]
	if selection == nil || selection.Kind() == types.FieldVal {
		return false
	}
	named := namedOf(selection.Recv())
	if named == nil || named.Obj().Pkg() == nil {
		return false
	}
	return f.w.Cfg.QueryCall(named.Obj().Pkg().Path(), sel.Sel.Name)
}

// auditQueries closes out a body: it reports a shortfall of readable statements
// against database calls, and it settles the overlay's account for a function
// that declared itself assembled.
//
// Fewer statements than calls means at least one arrived from outside this body.
// More is normal and not a finding: a migration list is a slice of statements
// driven through one `Exec` in a loop, and a helper may declare the statement its
// caller runs.
func (f *fnWalk) auditQueries() {
	if declared, ok := f.declared(); ok {
		f.settleDeclared(declared)
		return
	}
	if len(f.dbSites) <= f.sqlSeen {
		return
	}
	f.w.Rep.OpaqueQuery(f.w.Cfg.Rel(f.pkg.PkgPath), f.symName(), f.dbSites[0],
		fmt.Sprintf("%d database call(s) but only %d readable statement(s) in the body",
			len(f.dbSites), f.sqlSeen), remedyReadable)
}

// remedyReadable is what to do about text the extractor cannot read. It is
// attached to those findings only: each declaration finding below already says
// what to do about itself, and this instruction would contradict it.
const remedyReadable = "so the tables it names are missing from the map; keep the statement in one literal or constant expression, or declare its tables in `deps.sqlDriver.assembled`"

// declared returns the overlay's table list for this body, if it has one, and
// records that the declaration matched a real function.
func (f *fnWalk) declared() (map[string]string, bool) {
	tables, ok := f.w.Cfg.AssembledTables(f.w.Cfg.Rel(f.pkg.PkgPath), f.symName())
	if ok {
		f.w.claimed[f.declKey()] = true
	}
	return tables, ok
}

// settleDeclared draws the tables a human wrote down for an assembled statement,
// and reports the declaration when the source stopped needing it — an entry left
// behind after a query is simplified would go on asserting state that is no
// longer there, which is the same silence in the other direction.
func (f *fnWalk) settleDeclared(tables map[string]string) {
	pkg, fn := f.w.Cfg.Rel(f.pkg.PkgPath), f.symName()
	switch {
	case len(f.dbSites) == 0:
		f.w.Rep.OpaqueQuery(pkg, fn, f.declSite(),
			"the overlay declares the tables this function assembles, but it makes no database call", "")
		return
	case !f.opaqueSeen && len(f.dbSites) <= f.sqlSeen:
		f.w.Rep.OpaqueQuery(pkg, fn, f.dbSites[0],
			"the overlay declares the tables this function assembles, but every statement in it is now readable — delete the entry", "")
	}
	// A declaration accounts for the tables it names, not for every silence in the
	// body. Where the extractor could read a table name but not the statement around
	// it, that name is checked against the declaration too — otherwise adding a
	// `JOIN payouts` to an already-declared function would be absorbed by an entry
	// that says nothing about payouts.
	for _, name := range sortedKeys(f.opaqueTables) {
		if _, ok := tables[name]; ok {
			continue
		}
		f.w.Rep.OpaqueQuery(pkg, fn, f.opaqueTables[name], fmt.Sprintf(
			"the overlay declares the tables this function assembles, but text here names `%s`, which the declaration does not — add it",
			name), "")
	}
	for _, table := range sortedKeys(tables) {
		if !f.w.tables[table] {
			f.w.Rep.UnknownTable(table, f.dbSites[0])
			continue
		}
		f.record("pg."+table, tables[table], f.dbPos)
	}
}

// AuditAssembled reports a declaration that no function claimed. A name that
// matches nothing draws nothing, so an entry left behind by a rename would go on
// looking like an explanation while the map lost the tables it named.
//
// This runs once per service, after every route has been walked, so "claimed"
// means the walk actually reached the function — a declaration on code no
// endpoint can reach explains nothing about the map either.
func (w *Walker) AuditAssembled() {
	for key := range w.Cfg.AssembledDeclarations() {
		if w.claimed[key] {
			continue
		}
		pkg, fn := key, ""
		if i := strings.LastIndex(key, ":"); i >= 0 {
			pkg, fn = key[:i], key[i+1:]
		}
		w.Rep.OpaqueQuery(pkg, fn, key,
			"the overlay declares assembled tables under this name, but no function the walk reached has it — delete the entry or correct the name", "")
	}
}

// declKey is how the overlay names this function.
func (f *fnWalk) declKey() string {
	return f.w.Cfg.Rel(f.pkg.PkgPath) + ":" + f.symName()
}

// declSite cites the function's own declaration, for the one finding that is
// about the absence of a call rather than about a call.
func (f *fnWalk) declSite() string {
	return f.w.P.PosRef(f.declPos)
}

// noteCTEs remembers the WITH clauses this body declares. A statement assembled
// from several literals has its WITH clause in an earlier one than its FROM, so
// unlike `Tables` — which reads one whole statement and can see both — the scan
// here has to carry the names across the body.
func (f *fnWalk) noteCTEs(s string) {
	for _, m := range reCTE.FindAllStringSubmatch(normalizeSQL(s), -1) {
		if f.ctes == nil {
			f.ctes = map[string]bool{}
		}
		f.ctes[m[1]] = true
	}
}

// opaqueTable remembers a table whose name the extractor could read while the
// statement around it stayed dark, so a declaration can be held to it.
func (f *fnWalk) opaqueTable(name string, pos token.Pos) {
	if f.opaqueTables == nil {
		f.opaqueTables = map[string]string{}
	}
	if _, ok := f.opaqueTables[name]; !ok {
		f.opaqueTables[name] = f.w.P.PosRef(pos)
	}
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// reTableName finds each table-introducing keyword and the token that follows it.
//
// The keyword must be upper case: SQL in this tree is written that way, and the
// same words in prose ("update the entry from the fleet") would otherwise make
// every log message a finding. That is the check's blind spot — a statement
// written in lower case is scanned for nothing — and it is stated in the README
// beside the guarantee rather than only here.
//
// The keyword must also be followed by whitespace and a token that is neither
// empty nor a parenthesis, because neither of those names a table: `FOR UPDATE`
// ends a perfectly readable statement, and `FROM (SELECT ...)` opens a subquery
// whose own FROM is matched on its own. Accepting them made legal SQL a finding.
var reTableName = regexp.MustCompile(`\b(FROM|JOIN|INTO|UPDATE)[ \t\n\r]+([^\s,;()]+)`)

// reBareIdent is a table name the extractor can read: an identifier, optionally
// schema-qualified and optionally quoted. `Tables` accepts exactly this shape.
var reBareIdent = regexp.MustCompile(`^(?i:"?[a-z_][a-z0-9_$]*"?)(\.("?[a-z_][a-z0-9_$]*"?))?$`)

// auditText checks the text a literal or folded constant carries against the one
// thing the map needs from it: that a table it names can be read. `statement`
// says whether the text as a whole parsed as a statement, which is what
// separates a complete query from a fragment of one.
func (f *fnWalk) auditText(s string, pos token.Pos, statement bool) {
	// `EXTRACT(EPOCH FROM now() - created_at)` spells FROM without naming a table,
	// which is why `Tables` masks these calls; the same mask is what keeps them
	// from being read here as a table spliced in at run time.
	masked := string(maskKeywordCalls([]byte(s)))
	f.noteCTEs(masked)
	for _, m := range reTableName.FindAllStringSubmatch(masked, -1) {
		keyword, name := m[1], m[2]
		table := cleanIdent(strings.ToLower(name))
		switch {
		case sqlNoise[table]:
			continue // a keyword that may legally follow, e.g. `FROM ONLY t`
		case !reBareIdent.MatchString(name):
			f.opaque(pos, fmt.Sprintf("the table after `%s` is spliced in at run time (`%s`)",
				keyword, ellipsis(keyword+" "+name)))
		case !statement && f.w.tables[table] && !f.ctes[table]:
			f.opaqueTable(table, pos)
			f.opaque(pos, fmt.Sprintf("`%s` names a table but is only a fragment of a statement",
				ellipsis(s)))
		default:
			// Two ways a readable name is not a missing table edge. In a statement,
			// `Tables` already drew it. In a fragment, it names no table the schema
			// declares, or one this body shadowed with a CTE of the same name — the
			// earnings queries define `WITH providers AS (...)` and then `JOIN
			// providers p`, which is the CTE and not the providers table.
			//
			// Either way the scan has to keep going, because the table that is
			// missing may be the second one: stopping at the first readable name is
			// what let `fmt.Sprintf("... FROM models m JOIN %s ...")` publish clean.
			continue
		}
		return // one finding per literal is enough to act on
	}
}

// opaque reports unreadable text, unless the overlay already accounts for this
// body — in which case the fact that there was something to report is what makes
// the declaration current.
func (f *fnWalk) opaque(pos token.Pos, detail string) {
	f.opaqueSeen = true
	if _, ok := f.declared(); ok {
		return
	}
	f.w.Rep.OpaqueQuery(f.w.Cfg.Rel(f.pkg.PkgPath), f.symName(), f.w.P.PosRef(pos), detail, remedyReadable)
}

// symName renders the function as the report keys it, without the package
// prefix that the package field already carries.
func (f *fnWalk) symName() string {
	if f.sym.Recv == "" {
		return f.sym.Name
	}
	return f.sym.Recv + "." + f.sym.Name
}

// ellipsis keeps a finding readable when the text it quotes is a whole query. The
// cut backs up to a rune boundary, so quoting a statement that carries a name in
// it does not leave half a rune in the report.
func ellipsis(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) <= 60 {
		return s
	}
	cut := 57
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "..."
}
