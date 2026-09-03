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
	f.settleFragments()
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
// endpoint can reach explains nothing about the map either, which is why the
// finding names both possibilities rather than sending the reader after a rename
// that never happened.
//
// The claimed set is per walker while the declarations are per overlay, so a
// second service extractor would have to scope this by package before it reports
// the first service's entries as unmatched.
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
			"the overlay declares assembled tables under this name, but no function reachable from a route has it — correct the name, or delete the entry if the query moved off the route table", "")
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
//
// The names are scoped to the statement the text belongs to, not to the whole
// body. A body-wide set was both too coarse and order-dependent: a CTE in one
// query silenced a same-named real table in another, and hoisting a fragment into
// a local above the base statement flipped a clean function into a finding.
// `textScopeFor` picks that scope — the variable a query is assembled into, or
// failing that the statement the text appears in, which is what keeps two queries
// handed straight to the driver from sharing one CTE set.
//
// One scope holds more than one set, because store code reuses a local: each whole
// statement seen in a scope opens a new generation, and a fragment is settled
// against the generation that was current where the fragment was read. A single set
// per scope was still order-dependent in a way that could not be seen from the
// source — it was mutated during the walk and consulted after it, so whichever
// statement came last decided every fragment in the scope, silencing a real read in
// one order and reporting a legal query in the other.
func (f *fnWalk) noteCTEs(s string) {
	for _, m := range reCTEName.FindAllStringSubmatch(s, -1) {
		if f.ctes == nil {
			f.ctes = map[cteKey]map[string]bool{}
		}
		key := f.cteKey()
		if f.ctes[key] == nil {
			f.ctes[key] = map[string]bool{}
		}
		f.ctes[key][strings.ToLower(m[1])] = true
	}
}

// cteKey names the set of CTE names in force for the text being walked.
type cteKey struct {
	scope any
	gen   int
}

// generation is one query's worth of CTE names in a scope, and the statement that
// opened it.
type generation struct {
	n      int
	opener any
}

// cteKey is generation 1 until a second statement opens generation 2, so a fragment
// read before the statement it belongs to — a tail assembled above the base query —
// still finds that statement's CTE names.
func (f *fnWalk) cteKey() cteKey {
	gen := f.gens[f.textScope].n
	if gen == 0 {
		gen = 1
	}
	return cteKey{scope: f.textScope, gen: gen}
}

// openStatement starts a new generation of CTE names for the current scope, unless
// the statement being walked opened the current one already.
//
// The boundary is a binding, not a literal. A scope *rebound* is a scope whose
// previous statement's WITH clauses have stopped applying; a scope appended to is the
// same query still being assembled. Two shapes force that reading, and drawing the
// boundary at statement-shaped text broke both — silently, since orphaning a CTE name
// invents a table rather than losing one:
//
//   - one assignment, several literals: a long query spliced together routinely has a
//     middle literal that parses on its own (`SELECT DISTINCT account_id FROM
//     provider_earnings WHERE ...` between two CTE definitions). Reformatting the
//     coordinator's network-totals query — moving a line break, changing no SQL —
//     reported its own `providers` CTE as an undeclared table. Hence the opener check
//     here.
//   - several assignments, one query: `q := WITH usage AS (...)` then `q += SELECT ...
//     FROM models` then `q += UNION SELECT id FROM usage`, where the middle append is
//     also a statement on its own. Hence the caller's `textFresh` gate, which is what
//     distinguishes the append that continues a query from the assignment that starts
//     the next one.
func (f *fnWalk) openStatement() {
	if f.gens == nil {
		f.gens = map[any]generation{}
	}
	cur := f.gens[f.textScope]
	if cur.n > 0 && cur.opener == f.textStmt {
		return
	}
	f.gens[f.textScope] = generation{n: cur.n + 1, opener: f.textStmt}
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
//
// ONLY and LATERAL are stepped over rather than treated as the token, because
// they prefix a table name instead of replacing it — `Tables` reads through ONLY
// the same way, and a scan that stopped at the keyword would let `FROM ONLY %s`
// splice a table in unseen. The keywords that genuinely end the search (SELECT
// opening a subquery, UNNEST opening a function) are `sqlNoise`, which still lists
// ONLY and LATERAL for `Tables`' benefit — this pattern steps over them before they
// are ever looked up there.
//
// UPDATE reaches this pattern only where it heads an update statement, because
// `maskLockingClauses` has already blanked the clauses where it does not — see
// `auditText`.
var reTableName = regexp.MustCompile(`\b(FROM|JOIN|INTO|UPDATE)[ \t\n\r]+(?:(?:ONLY|LATERAL)[ \t\n\r]+)*([^\s,;()]+)`)

// reTrailingKeyword is the other half of demanding a token after the keyword.
// Requiring one is what stops `q += " FOR UPDATE"` from being a finding, but it
// also made `q += " JOIN " + other` — the same splice, concatenated instead of
// formatted — match nothing at all. A clause that ends *at* a table-introducing
// keyword is waiting for a name the extractor will never see.
//
// A literal ending `... WHERE id = $1 FOR UPDATE\n` is a complete, readable
// statement, and reporting it would red-light a correct map with no remedy that
// keeps the statement correct. That case does not reach here either: the mask has
// taken the words away before the search.
var reTrailingKeyword = regexp.MustCompile(`\b(FROM|JOIN|INTO|UPDATE)[ \t\n\r]+$`)

// reCTEName finds a WITH clause's name. Unlike `reCTE`, which reads a whole
// normalized statement, this runs over text as written and so demands upper-case
// keywords for the same reason `reTableName` does: every string in the body is
// scanned, and prose ("cannot rank with usage as (metric) unset") would
// otherwise register a CTE and switch the fragment check off.
var reCTEName = regexp.MustCompile(`(?:\bWITH|,)[ \t\n\r]+(?:RECURSIVE[ \t\n\r]+)?([A-Za-z_][A-Za-z0-9_$]*)[ \t\n\r]+AS[ \t\n\r]*\(`)

// reBareIdent is a table name the extractor can read: an identifier, optionally
// schema-qualified and optionally quoted. `Tables` accepts exactly this shape.
var reBareIdent = regexp.MustCompile(`^(?i:"?[a-z_][a-z0-9_$]*"?)(\.("?[a-z_][a-z0-9_$]*"?))?$`)

// auditText checks the text a literal or folded constant carries against the one
// thing the map needs from it: that a table it names can be read. `statement`
// says whether the text as a whole parsed as a statement, which is what
// separates a complete query from a fragment of one.
//
// A splice is decided here, because nothing later in the body can make `%s` into
// a name. A readable name in a fragment is only buffered, because whether it is
// a table or a CTE this body declares depends on text the walk may not have
// reached yet — `settleFragments` decides it once the body is done.
//
// Buffering happens before either finding is reported, and no finding stops the
// scan. A literal can be unreadable in one place and perfectly clear in another —
// `q += " FROM models m JOIN "` names `models` and then trails off — and the
// declaration check is held to every name the text gives up, not to the names in
// front of the first thing that went dark.
func (f *fnWalk) auditText(s string, pos token.Pos, statement bool) {
	// Two masks, both shared with `Tables` so the two readers agree on what a
	// keyword means. `EXTRACT(EPOCH FROM now() - created_at)` spells FROM without
	// naming a table; `FOR UPDATE`, `FOR NO KEY UPDATE` and `ON CONFLICT ... DO
	// UPDATE` spell UPDATE without heading a statement. Neither may be read here as
	// a table spliced in at run time.
	//
	// The locking mask is the upper-case one, because this is the only reader that
	// still has the case to judge by: a lower-case `for` ending a comment above an
	// upper-case `UPDATE ` + table is prose running into a splice, and masking it
	// hid exactly the splice this scan exists to find.
	masked := string(maskLockingClauses(maskKeywordCalls([]byte(s)), reLockingUpperCase))
	if statement && f.textFresh {
		f.openStatement()
	}
	f.noteCTEs(masked)
	var names []string
	spliced := ""
	for _, m := range reTableName.FindAllStringSubmatch(masked, -1) {
		keyword, name := m[1], m[2]
		table := cleanIdent(strings.ToLower(name))
		switch {
		case sqlNoise[table]:
			// A keyword that ends the search rather than naming a table: `FROM
			// (SELECT ...)`, `FROM UNNEST($1)`.
		case !reBareIdent.MatchString(name):
			if spliced == "" { // one finding per literal is enough to act on
				spliced = fmt.Sprintf("the table after `%s` is spliced in at run time (`%s`)",
					keyword, ellipsis(keyword+" "+name))
			}
		case !statement:
			names = append(names, table)
		default:
			// A readable name in a statement is not a missing edge: `Tables` drew it.
		}
		// The scan keeps going either way, because the table that is missing may be
		// the second one — stopping at the first name it could read is what let
		// `fmt.Sprintf("... FROM models m JOIN %s ...")` publish clean.
	}
	for _, table := range names {
		f.frags = append(f.frags, fragment{table: table, text: s, pos: pos, owner: f.cteKey()})
	}
	// One literal can trip several rules — a name it gives up, a keyword it ends at —
	// and the report keys findings by site, first one wins, so a reader is sent to the
	// line once. What must not stop is the accounting above it.
	if spliced != "" {
		f.opaque(pos, spliced)
		return
	}
	if m := reTrailingKeyword.FindStringSubmatch(masked); m != nil {
		f.opaque(pos, fmt.Sprintf("the text ends at `%s`, so the table that follows it is spliced in at run time (`%s`)",
			m[1], ellipsis(s)))
	}
}

// fragment is a table name read out of text that was not a whole statement,
// held until the CTE names of the statement it belongs to are all known.
type fragment struct {
	table string
	text  string
	pos   token.Pos
	owner cteKey // the statement this text was assembled into; see textScopeFor
}

// settleFragments decides the buffered fragment names once the whole body has
// been walked, so the verdict does not depend on whether the WITH clause was
// written above the FROM or hoisted into a local declared before it.
//
// Every non-CTE name is recorded, because a declaration is held to each table the
// text names; only the report stops at one finding per literal, which is all a
// reader needs to go and look.
func (f *fnWalk) settleFragments() {
	for _, fr := range f.frags {
		// A CTE of the same name shadows the table: the earnings queries define
		// `WITH providers AS (...)` and then `JOIN providers p`, which is the CTE and
		// not the providers table — and `providers` is a real table, so the schema
		// cannot settle this on its own.
		if f.ctes[fr.owner][fr.table] {
			continue
		}
		f.opaqueTable(fr.table, fr.pos)
		f.opaque(fr.pos, fmt.Sprintf("`%s` names a table but is only a fragment of a statement",
			ellipsis(fr.text)))
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
