package extract

import (
	"go/ast"
	"go/constant"
	"go/token"
	"go/types"
	"net/url"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
	"golang.org/x/tools/go/packages"
)

// Walker computes, for a function, the state a request reaching it can touch and
// the authorization gates it calls.
//
// There is deliberately no depth bound. Cycle detection already guarantees
// termination — the call graph is finite and a back edge is folded into the
// frame that owns it — and a depth cutoff would make a function's result depend
// on how it was reached, which a memo keyed by function alone cannot express: the
// first route to reach a handler at the cutoff would memoize a truncated answer
// and every later route would inherit it.
type Walker struct {
	P   *Program
	Cfg *config.Config
	Rep *report.Report

	gates  map[string]bool
	tables map[string]bool

	memo    map[string]*Result
	active  map[string]bool
	holders map[string]bool // structs already audited for concurrent state
	claimed map[string]bool // assembled-statement declarations a real function used
}

// Result is the evidence collected from one function and everything it calls.
type Result struct {
	Accesses []ir.Access

	// pending names the functions this result is still missing because they were
	// in progress further up the stack when we reached them. A result with a
	// non-empty pending set is incomplete for anyone but the callers currently
	// computing those functions, so it must not be memoized.
	pending map[string]bool
}

// NewWalker prepares a walker. Known tables come from the schema, so a query
// naming something that does not exist is reported rather than mapped.
func NewWalker(p *Program, cfg *config.Config, rep *report.Report) *Walker {
	return &Walker{
		P:       p,
		Cfg:     cfg,
		Rep:     rep,
		gates:   cfg.GateNames(),
		tables:  p.SchemaTables(),
		memo:    map[string]*Result{},
		active:  map[string]bool{},
		holders: map[string]bool{},
		claimed: map[string]bool{},
	}
}

// auditHolder reports a struct whose state only a package-wide rule explains.
//
// Reaching this point means an endpoint touched one of the struct's fields and the
// overlay had nothing to say about that field specifically — the node came from
// `deps.packageDefault`, or from `deps.inherit` rolling it up into whatever field
// it was reached through. That is fine for values. It is not fine for a type built
// to be mutated concurrently: that is a boundary of the system, and the map has to
// name it (or say `@skip` about it) rather than absorb it.
func (w *Walker) auditHolder(named *types.Named, via string, pos token.Pos) {
	if named == nil || named.Obj().Pkg() == nil {
		return
	}
	pkgPath := named.Obj().Pkg().Path()
	name := named.Obj().Name()
	key := pkgPath + ":" + name
	if w.holders[key] {
		return
	}
	w.holders[key] = true
	if w.Cfg.StructDeclared(pkgPath, name) {
		return
	}
	field, typ, ok := concurrentField(named, w.Cfg.Module())
	if !ok {
		return
	}
	w.Rep.AbsorbedState(w.Cfg.Rel(pkgPath), name, field, typ, via, w.P.PosRef(pos))
}

// Tables exposes the schema tables the walker validates against.
func (w *Walker) Tables() map[string]bool { return w.tables }

// Func returns the evidence for a function declaration, memoized.
func (w *Walker) Func(sym *FuncSym) *Result {
	if sym == nil || sym.Decl == nil || sym.Decl.Body == nil {
		return &Result{}
	}
	key := sym.key()
	if got, ok := w.memo[key]; ok {
		return got
	}
	if w.active[key] {
		// Back edge in a cycle. The in-progress computation up the stack already
		// covers this body, so returning empty avoids double counting — but the
		// caller must remember that its own result is short those facts, or a
		// later route would reuse a memo that is missing half a cycle.
		return &Result{pending: map[string]bool{key: true}}
	}
	w.active[key] = true
	f := &fnWalk{w: w, sym: sym, pkg: sym.Pkg, info: sym.Pkg.TypesInfo,
		varNode: map[types.Object]string{}, declPos: sym.Decl.Pos()}
	f.stmt(sym.Decl.Body)
	f.auditQueries()
	delete(w.active, key)
	// This frame just supplied its own body, so it is no longer pending for
	// anyone; whatever remains is a cycle still being unwound above us.
	delete(f.pending, key)
	res := &Result{Accesses: dedupeAccesses(f.out), pending: f.pending}
	if len(f.pending) == 0 {
		w.memo[key] = res
	}
	return res
}

// Lit returns the evidence for an inline function literal (a handler written
// directly in the route table).
func (w *Walker) Lit(pkg *packages.Package, lit *ast.FuncLit, label string) *Result {
	f := &fnWalk{w: w, sym: &FuncSym{Pkg: pkg, Name: label}, pkg: pkg, info: pkg.TypesInfo,
		varNode: map[types.Object]string{}, declPos: lit.Pos()}
	f.stmt(lit.Body)
	f.auditQueries()
	return &Result{Accesses: dedupeAccesses(f.out)}
}

// fnWalk walks one function body.
type fnWalk struct {
	w    *Walker
	sym  *FuncSym
	pkg  *packages.Package
	info *types.Info

	varNode map[types.Object]string // locals that alias mapped state
	calls   []*ast.CallExpr         // innermost call, for literal-mode context
	compare int                     // >0 while inside a comparison or switch tag
	pending map[string]bool         // in-progress callees this frame did not fold in

	// This body's side of the readable-statement checks: how much text was
	// recoverable here against how much the driver was handed. See queries.go.
	sqlSeen      int
	dbSites      []string
	dbPos        token.Pos                  // the first driver call, for citing a declared table
	declPos      token.Pos                  // this function's own declaration
	opaqueSeen   bool                       // unreadable text was found, reported or declared
	opaqueTables map[string]string          // tables named in unreadable text, and where
	textScope    any                        // what the text being walked belongs to; see textScopeFor
	textFresh    bool                       // this statement binds the scope rather than appending to it
	gens         map[any]int                // how many queries a scope has been bound to
	ctes         map[cteKey]map[string]bool // WITH clauses declared per assembled statement
	frags        []fragment                 // table names read out of fragments, settled at body end
	stmtTables   []statementTable           // tables named by whole statements, drawn at body end
	sent         map[cteKey]bool            // queries this body has handed to the driver
	alias        map[cteKey]cteKey          // a query copied into a second local: `r := q`
	openLoop     map[any]int                // the loop a scope's current query was opened inside
	loopSeq      int                        // loops entered, so each one has a name
	loopID       int                        // the innermost loop being walked, 0 outside any
	loopDispatch int                        // enclosing loops whose body calls the driver

	out []ir.Access
}

func (f *fnWalk) record(node, mode string, pos token.Pos) {
	if node == "" || mode == "" {
		return
	}
	f.out = append(f.out, ir.Access{Node: node, Mode: mode, Site: f.w.P.PosRef(pos), Via: f.sym.Label()})
}

func (f *fnWalk) merge(res *Result) {
	f.out = append(f.out, res.Accesses...)
	for key := range res.pending {
		if f.pending == nil {
			f.pending = map[string]bool{}
		}
		f.pending[key] = true
	}
}

// ---------------------------------------------------------------------------
// statements

// stmt walks a statement with the text scope set to whatever that statement
// assembles into, so the SQL inside it is read as belonging to one query rather
// than to the body at large. See textScopeFor.
func (f *fnWalk) stmt(s ast.Stmt) {
	prevScope, prevFresh := f.textScope, f.textFresh
	if scope := f.textScopeFor(s); scope != nil {
		f.textScope, f.textFresh = scope, bindsScope(s)
		if f.textFresh && (f.queryIsOver(scope) || !f.readsScope(s)) {
			f.openStatement()
		}
	}
	f.walkStmt(s)
	f.textScope, f.textFresh = prevScope, prevFresh
}

// textElem walks an expression that stands for a query of its own — an element of a
// composite literal, an argument to a call, one of several values a statement binds
// or returns — with the text scope set to the expression itself.
//
// Without this, a statement holding several queries pooled their CTE names, and one
// query's `WITH usage AS (…)` muted a real read of the `usage` table in the next.
// `migrations := []string{…}` in the store is a hundred statements in one scope; a
// slice built as `[]string{base, base + " JOIN usage u"}`, or two queries handed to
// one call, are the same shape at a size where nobody would notice the mute. Scoping
// per element only ever narrows a scope, so it can turn a silence into a finding and
// never the reverse.
//
// A query genuinely assembled across two elements is the cost, and it is a finding
// with a remedy (inline the `WITH`, or declare the tables) rather than a wrong edge.
func (f *fnWalk) textElem(e ast.Expr, mode string) {
	prevScope, prevFresh := f.textScope, f.textFresh
	f.textScope, f.textFresh = e, true
	f.visit(e, mode)
	f.textScope, f.textFresh = prevScope, prevFresh
}

// bindsScope reports whether a statement gives its text scope a new value rather
// than adding to the value already there. `q := ...` and `q = ...` start a query;
// `q += ...` continues the one already in q. Every other statement kind that owns a
// scope owns a fresh one, because the scope is the statement itself.
//
// This is what decides where one query ends and the next begins — see
// `openStatement`. Deciding it from the text instead was wrong in a way no test
// caught until a query was assembled in three steps: the middle `+=` of
// `q := WITH ... ; q += SELECT ... FROM models ; q += UNION ... FROM usage` parses
// as a statement on its own, so it opened a generation the WITH clause above it was
// not in, and the query's own CTE was reported as an undeclared table.
func bindsScope(s ast.Stmt) bool {
	if a, ok := s.(*ast.AssignStmt); ok {
		return a.Tok == token.ASSIGN || a.Tok == token.DEFINE
	}
	return true
}

// readsScope reports whether a binding builds its new value out of the old one:
// `q = "WITH ... " + q`, `q = strings.TrimSpace(q)`. Syntactically that rebinds the
// scope; semantically it is the same query still being assembled, and the text
// already read into the current generation belongs with the text arriving now.
//
// Without this, a query assembled tail-first — the `UNION` collected into q, then
// the base and its `WITH` clause prepended — would put the tail and the WITH clause
// that covers it in different generations and report the query's own CTE as a table.
//
// It is only asked while the query is still unsent: see queryIsOver. Text handed to
// the database is a query that is over, and prepending a `WITH` clause to what is left
// of the local cannot reach back and shadow a table that query read.
func (f *fnWalk) readsScope(s ast.Stmt) bool {
	a, ok := s.(*ast.AssignStmt)
	if !ok {
		return false
	}
	found := false
	for _, rhs := range a.Rhs {
		ast.Inspect(rhs, func(n ast.Node) bool {
			id, ok := n.(*ast.Ident)
			if !ok || found {
				return !found
			}
			if obj := f.objOf(id); obj != nil && any(obj) == f.textScope {
				found = true
			}
			return !found
		})
	}
	return found
}

// queryIsOver reports whether the query this scope currently holds has already gone
// to the database. If it has, a rebinding that quotes the local is a second query
// reusing what is left of the first rather than the same one assembled tail first —
// so its `WITH` clause must not reach back and shadow a table the finished query
// really read. That is the whole of the tail-first exception's expiry; see readsScope.
//
// Two things end a query. It was handed to the driver: marked at the call site from
// the locals that call names, and through `r := q` copies, so a dispatch under another
// name counts (`noteSent`). Or the rebinding is inside a loop that calls the driver
// while the query was opened outside that loop: the walk sees the body once and the
// program runs it many times, so on the second pass the local already holds a query
// that ran.
//
// Attributing a call to the query it dispatched is what keeps this from cutting an
// unrelated one. Counting the body's calls instead let `Exec(ctx, "SELECT …")` on some
// other statement end the exception for a query that had not run — which reported a
// legal assembly *and* drew the table that query's own CTE was shadowing.
func (f *fnWalk) queryIsOver(scope any) bool {
	if f.sent[cteKey{scope: scope, gen: f.gens[scope]}] {
		return true
	}
	return f.loopDispatch > 0 && f.openLoop[scope] != f.loopID
}

// loopBody walks a loop's body as a loop. Nothing else about the walk depends on how
// often a statement runs; the tail-first exception does, because it is an argument
// about what a local held a moment ago. See queryIsOver.
func (f *fnWalk) loopBody(body *ast.BlockStmt) {
	prevID, prevDispatch := f.loopID, f.loopDispatch
	f.loopSeq++
	f.loopID = f.loopSeq
	if f.hasQueryCall(body) {
		f.loopDispatch++
	}
	f.stmt(body)
	f.loopID, f.loopDispatch = prevID, prevDispatch
}

// hasQueryCall reports whether a driver call appears inside a node.
//
// Only a direct call counts. A dispatch through a helper is invisible here exactly as
// it is to the statement count — this body's `dbSites` never sees the callee's Exec —
// so the exception survives it, which is the same answer this check gave before loops
// were tracked at all.
func (f *fnWalk) hasQueryCall(n ast.Node) bool {
	found := false
	ast.Inspect(n, func(n ast.Node) bool {
		if found {
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if sel, ok := unparen(call.Fun).(*ast.SelectorExpr); ok && f.isQueryCall(sel) {
			found = true
			return false
		}
		return true
	})
	return found
}

// textScopeFor names what the statement text inside s belongs to.
//
// An assignment to a single string variable is the strongest answer: a query built
// up over several lines is built into one local. Failing that the statement itself
// is the scope, which is what keeps two statements handed straight to the driver —
// `Exec(ctx, a)` then `Exec(ctx, b)` — from sharing one CTE set.
//
// Every statement kind answers, including the composite ones. Those used to return
// nil, on the reasoning that the statements nested inside them answer for themselves
// — which they do, but the text in the composite statement's *own* expressions does
// not: an `if` condition, a `switch` tag, a `range` expression and a `case` value all
// fell through to the body-wide zero scope, where a string shaped like `WITH usage AS
// (` in one condition could shadow a real read of `usage` appended in another. Owning
// a scope only ever narrows one, so a composite statement owning its own can turn a
// silence into a finding and never the reverse.
func (f *fnWalk) textScopeFor(s ast.Stmt) any {
	switch x := s.(type) {
	case nil:
		return nil
	case *ast.AssignStmt:
		if target := f.assignTarget(x.Lhs); target != nil {
			return target
		}
	}
	return s
}

func (f *fnWalk) walkStmt(s ast.Stmt) {
	switch x := s.(type) {
	case nil:
		return
	case *ast.BlockStmt:
		for _, st := range x.List {
			f.stmt(st)
		}
	case *ast.ExprStmt:
		f.visit(x.X, ModeRead)
	case *ast.AssignStmt:
		// Several values bound in one statement are several queries. `base, tail :=
		// q1, q2` has no single target, so both values used to fall back to the
		// statement — where one query's `WITH usage AS (…)` shadowed the other's real
		// read of `usage`, the mute textElem exists to break. A lone value is already
		// alone in its scope, and scoping it to itself would only lose the local.
		if len(x.Rhs) > 1 {
			for _, rhs := range x.Rhs {
				f.textElem(rhs, ModeRead)
			}
		} else {
			for _, rhs := range x.Rhs {
				f.visit(rhs, ModeRead)
			}
		}
		f.noteTextAlias(x.Lhs, x.Rhs)
		f.bindVars(x)
		if x.Tok == token.DEFINE {
			return // the left side declares new locals; nothing is mutated
		}
		for _, lhs := range x.Lhs {
			f.visit(lhs, ModeWrite)
		}
	case *ast.IncDecStmt:
		f.visit(x.X, ModeWrite)
	case *ast.DeclStmt:
		if gen, ok := x.Decl.(*ast.GenDecl); ok {
			for _, spec := range gen.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				// `var q = ...` scopes its text the same way an assignment does, and
				// `var a, b = q1, q2` scopes each value to itself for the same reason a
				// multi-value assignment does.
				prevScope, prevFresh := f.textScope, f.textFresh
				switch obj := f.assignTarget(identExprs(vs.Names)); {
				case obj != nil:
					f.textScope, f.textFresh = obj, true
					f.openStatement() // the declaration binds q, so it starts a query; see stmt
					for _, v := range vs.Values {
						f.visit(v, ModeRead)
					}
				case len(vs.Values) > 1:
					for _, v := range vs.Values {
						f.textElem(v, ModeRead)
					}
				default:
					for _, v := range vs.Values {
						f.visit(v, ModeRead)
					}
				}
				f.textScope, f.textFresh = prevScope, prevFresh
				f.noteTextAlias(identExprs(vs.Names), vs.Values)
				f.bindSpec(vs)
			}
		}
	case *ast.ReturnStmt:
		// A helper handing two statements back — `return base, tail` — is two queries
		// in one statement, with the same mute in it as a multi-value binding.
		if len(x.Results) > 1 {
			for _, r := range x.Results {
				f.textElem(r, ModeRead)
			}
			return
		}
		for _, r := range x.Results {
			f.visit(r, ModeRead)
		}
	case *ast.IfStmt:
		f.stmt(x.Init)
		f.compare++
		f.visit(x.Cond, ModeRead)
		f.compare--
		f.stmt(x.Body)
		f.stmt(x.Else)
	case *ast.ForStmt:
		f.stmt(x.Init)
		f.compare++
		f.visit(x.Cond, ModeRead)
		f.compare--
		f.stmt(x.Post)
		f.loopBody(x.Body)
	case *ast.RangeStmt:
		f.visit(x.X, ModeRead)
		f.bindRange(x)
		f.loopBody(x.Body)
	case *ast.SwitchStmt:
		f.stmt(x.Init)
		f.compare++
		f.visit(x.Tag, ModeRead)
		f.compare--
		f.stmt(x.Body)
	case *ast.TypeSwitchStmt:
		f.stmt(x.Init)
		f.stmt(x.Assign)
		f.stmt(x.Body)
	case *ast.CaseClause:
		f.compare++
		for _, e := range x.List {
			f.visit(e, ModeRead)
		}
		f.compare--
		for _, st := range x.Body {
			f.stmt(st)
		}
	case *ast.SelectStmt:
		f.stmt(x.Body)
	case *ast.CommClause:
		f.stmt(x.Comm)
		for _, st := range x.Body {
			f.stmt(st)
		}
	case *ast.GoStmt:
		f.visit(x.Call, ModeRead)
	case *ast.DeferStmt:
		f.visit(x.Call, ModeRead)
	case *ast.SendStmt:
		f.visit(x.Chan, ModeWrite)
		f.visit(x.Value, ModeRead)
	case *ast.LabeledStmt:
		f.stmt(x.Stmt)
	case *ast.BranchStmt, *ast.EmptyStmt:
		return
	}
}

// assignTarget names the single variable an assignment writes, which is what
// scopes the statement text on its right.
//
// Three things disqualify a target, and all three mean the same thing: the text
// cannot be attributed to one query, so the statement it appears in is used
// instead. Several targets has no single one — `_, err := db.Exec(ctx, q)` writes
// err, not the query. A target that cannot hold text is not the query either:
// scoping by `err` in `err = QueryRow(...).Scan(&x)` would pool every query in the
// body under one name, and one CTE would shadow them all.
//
// Anything that is not a bare identifier — `qs[0]`, `s.q`, `*p` — is left to the
// statement fallback rather than resolved to the variable underneath it. Digging
// through to that variable looks helpful and is not: `qs[0]` and `qs[1]` resolve to
// the same slice and `a.q` and `b.q` to the same field object, so a CTE in one
// element or one receiver would shadow a real table read in another — the silence
// this check exists to break. Falling back reports a query assembled that way
// instead, which the remedy (inline the WITH clause, or declare the tables) can
// answer. No store query in the tree is assembled through an index or a field.
func (f *fnWalk) assignTarget(lhs []ast.Expr) types.Object {
	if len(lhs) != 1 {
		return nil
	}
	ident, ok := lhs[0].(*ast.Ident)
	if !ok {
		return nil
	}
	obj := f.objOf(ident)
	if obj == nil || obj.Type() == nil || !carriesText(obj.Type()) {
		return nil
	}
	return obj
}

// carriesText reports whether a value of this type can hold statement text.
//
// A type parameter is answered from its type set rather than from its underlying
// type, which is the constraint interface and holds nothing. `func q[T ~string]`
// builds a query in a T exactly the way the store builds one in a string, and
// reading the interface would have scoped the `WITH` clause and the fragment
// appended to it apart — a finding against SQL that is entirely correct.
func carriesText(t types.Type) bool {
	if tp, ok := t.(*types.TypeParam); ok {
		return typeSetIsText(tp.Constraint())
	}
	basic, ok := t.Underlying().(*types.Basic)
	return ok && basic.Info()&types.IsString != 0
}

// typeSetIsText reports whether every type a constraint admits is a string. Every
// one, not any: a `~string | []byte` parameter can hold a query in one instantiation
// and something else in another, and treating the two as one query is the shadowing
// this check exists to prevent.
func typeSetIsText(constraint types.Type) bool {
	iface, ok := constraint.Underlying().(*types.Interface)
	if !ok || iface.NumEmbeddeds() == 0 {
		return false // `any`, or a method-only constraint: nothing to read
	}
	for i := range iface.NumEmbeddeds() {
		emb := iface.EmbeddedType(i)
		if _, ok := emb.Underlying().(*types.Interface); ok {
			// A constraint embedding another one: its type set is the same question.
			if !typeSetIsText(emb) {
				return false
			}
			continue
		}
		union, ok := emb.(*types.Union)
		if !ok {
			if !carriesText(emb) { // a single non-union term
				return false
			}
			continue
		}
		for j := range union.Len() {
			if !carriesText(union.Term(j).Type()) {
				return false
			}
		}
	}
	return true
}

// bindVars propagates node attribution through `x := s.registry` so later uses
// of the local are still attributed to the state it aliases.

func identExprs(names []*ast.Ident) []ast.Expr {
	out := make([]ast.Expr, len(names))
	for i, name := range names {
		out[i] = name
	}
	return out
}

func (f *fnWalk) bindVars(a *ast.AssignStmt) {
	if len(a.Lhs) != len(a.Rhs) {
		return
	}
	for i, lhs := range a.Lhs {
		ident, ok := lhs.(*ast.Ident)
		if !ok {
			continue
		}
		node := f.nodeOf(a.Rhs[i])
		if node == "" {
			continue
		}
		if obj := f.objOf(ident); obj != nil {
			f.varNode[obj] = node
		}
	}
}

func (f *fnWalk) bindSpec(vs *ast.ValueSpec) {
	if len(vs.Names) != len(vs.Values) {
		return
	}
	for i, name := range vs.Names {
		if node := f.nodeOf(vs.Values[i]); node != "" {
			if obj := f.objOf(name); obj != nil {
				f.varNode[obj] = node
			}
		}
	}
}

// bindRange attributes loop variables to the collection they iterate, so
// `for _, p := range s.registry.Providers()` keeps attribution on the registry.
func (f *fnWalk) bindRange(r *ast.RangeStmt) {
	node := f.nodeOf(r.X)
	if node == "" {
		return
	}
	for _, key := range []ast.Expr{r.Key, r.Value} {
		ident, ok := key.(*ast.Ident)
		if !ok || ident.Name == "_" {
			continue
		}
		if obj := f.objOf(ident); obj != nil {
			f.varNode[obj] = node
		}
	}
}

func (f *fnWalk) objOf(ident *ast.Ident) types.Object {
	if obj := f.info.Defs[ident]; obj != nil {
		return obj
	}
	return f.info.Uses[ident]
}

// ---------------------------------------------------------------------------
// expressions

// visit records the access an expression implies and descends into the parts of
// it that are not covered by that attribution.
//
// Only the outermost mapped node of a selector chain is recorded: `s.exactCache.
// entries[key] = v` is one write to the exact-cache node, not also a read of the
// server struct.
func (f *fnWalk) visit(e ast.Expr, mode string) {
	switch x := e.(type) {
	case nil:
		return
	case *ast.ParenExpr:
		f.visit(x.X, mode)
	case *ast.BasicLit:
		f.literal(x)
	case *ast.FuncLit:
		f.stmt(x.Body)
	case *ast.CompositeLit:
		for _, el := range x.Elts {
			f.textElem(el, ModeRead)
		}
	case *ast.KeyValueExpr:
		f.visit(x.Key, ModeRead)
		f.visit(x.Value, ModeRead)
	case *ast.BinaryExpr:
		// A statement or URL assembled from constants — `"SELECT " + userColumns +
		// " FROM users"` — is a single string as far as the program is concerned, and
		// go/types has already folded it. Classifying the operands one at a time
		// would only ever see fragments, and " FROM users WHERE id = $1" is not a
		// statement, so the table would go unrecorded while the report stayed clean.
		if f.constant(x) {
			return
		}
		if x.Op == token.EQL || x.Op == token.NEQ {
			f.compare++
			f.visit(x.X, ModeRead)
			f.visit(x.Y, ModeRead)
			f.compare--
			return
		}
		f.visit(x.X, ModeRead)
		f.visit(x.Y, ModeRead)
	case *ast.UnaryExpr:
		if x.Op == token.AND { // taking an address can mutate through the pointer
			f.visit(x.X, mode)
			return
		}
		f.visit(x.X, ModeRead)
	case *ast.StarExpr:
		f.visit(x.X, mode)
	case *ast.TypeAssertExpr:
		f.visit(x.X, mode)
	case *ast.SliceExpr:
		f.visitChain(x, x.X, mode)
		f.visit(x.Low, ModeRead)
		f.visit(x.High, ModeRead)
		f.visit(x.Max, ModeRead)
	case *ast.IndexExpr:
		f.visitChain(x, x.X, mode)
		f.visit(x.Index, ModeRead)
	case *ast.IndexListExpr:
		f.visitChain(x, x.X, mode)
	case *ast.SelectorExpr:
		f.visitChain(x, x.X, mode)
	case *ast.Ident:
		if node := f.nodeOf(x); node != "" {
			f.record(node, mode, x.Pos())
			return
		}
		f.constant(x)
	case *ast.CallExpr:
		f.call(x, false)
	}
}

// visitChain records the node for a chained expression, then walks the chain for
// nested evidence (call arguments, index keys) without re-attributing its links.
func (f *fnWalk) visitChain(whole, inner ast.Expr, mode string) {
	if node := f.nodeOf(whole); node != "" {
		if f.isMessageConst(whole) && f.compare == 0 {
			// A protocol constant built into an outbound frame is a write to
			// that socket surface; the same constant compared against an
			// inbound frame is a read.
			mode = ModeWrite
		}
		f.record(node, mode, whole.Pos())
		f.chain(inner)
		return
	}
	// A package-qualified constant is a surface only if it is not already a node
	// (protocol message types are), so this is checked after node attribution.
	if sel, ok := unparen(whole).(*ast.SelectorExpr); ok && f.info.Selections[sel] == nil {
		if f.constant(sel) {
			return
		}
	}
	// The mode carries down the chain instead of decaying to a read: writing
	// `x.f`, `x[k]` or `*x` mutates whatever holds the leaf, so when the node the
	// map draws is one link further up — the receiver's type, or a field the
	// overlay skips — a write stays a write. A cache whose fill is
	// `c.entries[k] = v` behind a `@skip`ped field would otherwise be published
	// read-only. Index keys and call arguments are visited as reads separately, so
	// this only widens the mode of the thing being written through.
	f.visit(inner, mode)
}

// chain walks a selector chain purely for side evidence.
func (f *fnWalk) chain(e ast.Expr) {
	switch x := e.(type) {
	case *ast.ParenExpr:
		f.chain(x.X)
	case *ast.SelectorExpr:
		f.chain(x.X)
	case *ast.StarExpr:
		f.chain(x.X)
	case *ast.TypeAssertExpr:
		f.chain(x.X)
	case *ast.UnaryExpr:
		f.chain(x.X)
	case *ast.SliceExpr:
		f.chain(x.X)
	case *ast.IndexExpr:
		f.chain(x.X)
		f.visit(x.Index, ModeRead)
	case *ast.CallExpr:
		f.call(x, true)
	}
}

// call records the access a method call implies on its receiver's node, detects
// authorization gates, and follows the callee when it is in traversal scope.
func (f *fnWalk) call(x *ast.CallExpr, suppressRecv bool) {
	f.calls = append(f.calls, x)
	defer func() { f.calls = f.calls[:len(f.calls)-1] }()

	// Builtins that mutate their argument.
	if ident, ok := x.Fun.(*ast.Ident); ok {
		if _, isBuiltin := f.info.Uses[ident].(*types.Builtin); isBuiltin {
			mode := ModeRead
			if ident.Name == "delete" || ident.Name == "clear" {
				mode = ModeWrite
			}
			for i, arg := range x.Args {
				if i == 0 {
					f.visit(arg, mode)
					continue
				}
				f.visit(arg, ModeRead)
			}
			return
		}
	}

	// An immediately-invoked literal — `go func() { ... }()`, the shape every
	// bounded-concurrency worker in this service uses — carries its body in the
	// call's own Fun, so a walk that only followed named callees would stop at the
	// goroutine boundary.
	if lit, ok := unparen(x.Fun).(*ast.FuncLit); ok {
		f.stmt(lit.Body)
	}

	fn := funcObject(f.info, x.Fun)
	if sel, ok := unparen(x.Fun).(*ast.SelectorExpr); ok {
		if f.isQueryCall(sel) {
			if len(f.dbSites) == 0 {
				f.dbPos = x.Pos()
			}
			f.dbSites = append(f.dbSites, f.w.P.PosRef(x.Pos()))
			f.noteSent(x.Args)
		}
		if selection := f.info.Selections[sel]; selection != nil && selection.Kind() != types.FieldVal {
			recvType := selection.Recv()
			mode := syncMode(recvType, sel.Sel.Name)
			if mode == "" {
				mode = verbMode(sel.Sel.Name)
			}
			if node := f.nodeOf(sel.X); node != "" && !suppressRecv {
				f.record(node, mode, x.Pos())
			}
			f.chain(sel.X)
		} else {
			f.chain(sel.X)
		}
	}

	for _, arg := range x.Args {
		f.textElem(arg, ModeRead)
	}
	f.traverse(x, fn)
}

// traverse follows a call into the callee's body, resolving interface dispatch
// to the implementation the overlay prefers (the Postgres store, so the SQL
// behind a store method is recovered).
func (f *fnWalk) traverse(x *ast.CallExpr, fn *types.Func) {
	if fn == nil {
		return
	}
	for _, target := range f.targets(x, fn) {
		if target == nil || target.Pkg == nil {
			continue
		}
		// A function that *is* a boundary is evidence at the call site, whether or
		// not its package is in traversal scope.
		if node, ok := f.w.Cfg.FuncNode(target.Pkg.PkgPath, target.Recv, target.Name); ok {
			f.record(node, verbMode(target.Name), x.Pos())
		}
		if !f.w.Cfg.Traverse(target.Pkg.PkgPath) {
			continue
		}
		f.merge(f.w.Func(target))
	}
}

// targets resolves a call to the declarations it can reach.
func (f *fnWalk) targets(x *ast.CallExpr, fn *types.Func) []*FuncSym {
	sel, _ := unparen(x.Fun).(*ast.SelectorExpr)
	if sel != nil {
		if selection := f.info.Selections[sel]; selection != nil && selection.Kind() != types.FieldVal {
			if iface, ok := types.Unalias(selection.Recv()).Underlying().(*types.Interface); ok {
				return f.implTargets(iface, fn.Name())
			}
			if named := namedOf(selection.Recv()); named != nil {
				if iface, ok := named.Underlying().(*types.Interface); ok {
					return f.implTargets(iface, fn.Name())
				}
			}
		}
	}
	if sym := f.w.P.DeclOf(fn); sym != nil {
		return []*FuncSym{sym}
	}
	return nil
}

func (f *fnWalk) implTargets(iface *types.Interface, method string) []*FuncSym {
	impls := f.w.P.Implementations(iface)
	var preferred []*types.Named
	for _, named := range impls {
		if f.w.Cfg.PreferImpl(named.Obj().Name()) {
			preferred = append(preferred, named)
		}
	}
	if len(preferred) > 0 {
		impls = preferred
	}
	var out []*FuncSym
	for _, named := range impls {
		if named.Obj().Pkg() == nil {
			continue
		}
		if sym := f.w.P.Method(named.Obj().Pkg().Path(), named.Obj().Name(), method); sym != nil {
			out = append(out, sym)
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// node attribution

// nodeOf resolves the dependency node an expression refers to, or "" when it
// refers to nothing the map tracks. State the overlay does not explain is
// recorded as drift here, at the point where evidence exists for it.
func (f *fnWalk) nodeOf(e ast.Expr) string {
	switch x := e.(type) {
	case nil:
		return ""
	case *ast.ParenExpr:
		return f.nodeOf(x.X)
	case *ast.StarExpr:
		return f.nodeOf(x.X)
	case *ast.TypeAssertExpr:
		return f.nodeOf(x.X)
	case *ast.UnaryExpr:
		return f.nodeOf(x.X)
	case *ast.IndexExpr:
		return f.nodeOf(x.X)
	case *ast.IndexListExpr:
		return f.nodeOf(x.X)
	case *ast.SliceExpr:
		return f.nodeOf(x.X)
	case *ast.CallExpr:
		if sel, ok := unparen(x.Fun).(*ast.SelectorExpr); ok {
			if selection := f.info.Selections[sel]; selection != nil && selection.Kind() != types.FieldVal {
				if node := f.nodeOf(sel.X); node != "" {
					return node
				}
			}
		}
		return f.typeNode(f.info.TypeOf(x))
	case *ast.Ident:
		obj := f.objOf(x)
		if v, ok := obj.(*types.Var); ok {
			if node, ok := f.varNode[v]; ok {
				return node
			}
			return f.typeNode(v.Type())
		}
		return ""
	case *ast.SelectorExpr:
		return f.selectorNode(x)
	}
	return ""
}

func (f *fnWalk) selectorNode(x *ast.SelectorExpr) string {
	selection := f.info.Selections[x]
	if selection == nil {
		// Package-qualified identifier: protocol message constants are the
		// surfaces we care about here.
		if c, ok := f.info.Uses[x.Sel].(*types.Const); ok && c.Pkg() != nil {
			if node, ok := f.w.Cfg.MessageNode(c.Pkg().Path(), c.Name()); ok {
				return node
			}
		}
		if v, ok := f.info.Uses[x.Sel].(*types.Var); ok {
			return f.typeNode(v.Type())
		}
		return ""
	}
	if selection.Kind() != types.FieldVal {
		if node := f.nodeOf(x.X); node != "" {
			return node
		}
		return f.typeNode(selection.Recv())
	}
	field, _ := selection.Obj().(*types.Var)
	if field == nil {
		return ""
	}
	named := namedOf(selection.Recv())
	if named == nil || named.Obj().Pkg() == nil {
		return ""
	}
	structPkg := named.Obj().Pkg().Path()
	structName := named.Obj().Name()
	node, src := f.w.Cfg.FieldNode(structPkg, structName, field.Name())
	switch src {
	case config.FieldExplicit:
		return node
	case config.FieldDefault:
		f.w.auditHolder(named, "deps.packageDefault", x.Pos())
		return node
	}
	if node := f.typeNode(field.Type()); node != "" {
		return node
	}
	if f.w.Cfg.Inherits(structPkg) {
		f.w.auditHolder(named, "deps.inherit", x.Pos())
		return f.nodeOf(x.X)
	}
	if strings.HasPrefix(structPkg, f.w.Cfg.Module()) {
		f.w.Rep.UnmappedField(f.w.Cfg.Rel(structPkg), structName, field.Name(),
			shortType(field.Type()), f.w.P.PosRef(x.Pos()))
	}
	return ""
}

func (f *fnWalk) typeNode(t types.Type) string {
	pkgPath, name, ok := typeKey(t)
	if !ok {
		return ""
	}
	node, _ := f.w.Cfg.TypeNode(pkgPath, name)
	return node
}

func (f *fnWalk) isMessageConst(e ast.Expr) bool {
	sel, ok := unparen(e).(*ast.SelectorExpr)
	if !ok || f.info.Selections[sel] != nil {
		return false
	}
	c, ok := f.info.Uses[sel.Sel].(*types.Const)
	if !ok || c.Pkg() == nil {
		return false
	}
	_, mapped := f.w.Cfg.MessageNode(c.Pkg().Path(), c.Name())
	return mapped
}

// ---------------------------------------------------------------------------
// literals: SQL, external hosts, remote endpoint paths

func (f *fnWalk) literal(lit *ast.BasicLit) {
	if s, ok := stringLit(lit); ok {
		f.classify(s, lit.Pos())
	}
}

// constant classifies a named string constant by its value. The coordinator
// keeps outbound base URLs in package-level constants
// (defaultModelRegistryCDNBaseURL), so a walk that only looked at literals in
// the expression it is standing on would miss the boundary entirely. go/types
// already computed the value, so this stays derived rather than guessed.
func (f *fnWalk) constant(e ast.Expr) bool {
	tv, ok := f.info.Types[e]
	if !ok || tv.Value == nil || tv.Value.Kind() != constant.String {
		return false
	}
	s := constant.StringVal(tv.Value)
	if len(s) == 0 {
		return false
	}
	f.classify(s, e.Pos())
	return true
}

func (f *fnWalk) classify(s string, pos token.Pos) {
	// The endpoint table is keyed by the literal exactly as written, so a
	// sidecar URL like "http://promptsidecar/v1/plan" resolves to that remote
	// surface rather than being read as an external host.
	if node, ok := f.w.Cfg.EndpointNode(f.pkg.PkgPath, s); ok {
		f.record(node, f.ioMode(), pos)
		return
	}
	switch {
	case IsSQL(s):
		f.sqlSeen++
		f.auditText(s, pos, true)
		f.noteTables(s, pos)
	case strings.Contains(s, "://"):
		host := hostOf(s)
		if host == "" || isLocalHost(host) {
			return
		}
		node, ok := f.w.Cfg.HostNode(host)
		if !ok {
			f.w.Rep.UnknownHost(host, f.w.P.PosRef(pos))
			return
		}
		f.record(node, f.ioMode(), pos)
	default:
		// Text that did not parse as a statement but still names a table is a
		// fragment of one, assembled at run time out of the extractor's sight.
		f.auditText(s, pos, false)
	}
}

// ioMode classifies an outbound request from the call the literal feeds: a
// fetch reads the remote surface, a post writes it, and anything else is a
// request/response round trip.
func (f *fnWalk) ioMode() string {
	for i := len(f.calls) - 1; i >= 0; i-- {
		fn := funcObject(f.info, f.calls[i].Fun)
		if fn == nil {
			continue
		}
		name := fn.Name()
		switch {
		case strings.HasPrefix(name, "Get"), strings.HasPrefix(name, "Fetch"),
			strings.HasPrefix(name, "List"), strings.HasPrefix(name, "Query"),
			strings.HasPrefix(name, "Lookup"), strings.HasPrefix(name, "Read"):
			return ModeRead
		case strings.HasPrefix(name, "Post"), strings.HasPrefix(name, "Put"),
			strings.HasPrefix(name, "Delete"), strings.HasPrefix(name, "Send"),
			strings.HasPrefix(name, "Push"), strings.HasPrefix(name, "Create"),
			strings.HasPrefix(name, "Update"), strings.HasPrefix(name, "Remove"):
			return ModeWrite
		}
	}
	return ModeBoth
}

func hostOf(s string) string {
	i := strings.Index(s, "://")
	if i < 0 {
		return ""
	}
	// Trim anything before the scheme (log prefixes, format strings).
	start := strings.LastIndexAny(s[:i], " \t\"'=(,") + 1
	u, err := url.Parse(strings.TrimSpace(s[start:]))
	if err != nil {
		return ""
	}
	return u.Hostname()
}

func isLocalHost(host string) bool {
	switch host {
	case "localhost", "127.0.0.1", "::1", "0.0.0.0", "example.com", "example.org", "host":
		return true
	}
	return strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".invalid") ||
		strings.HasPrefix(host, "%s") || strings.HasPrefix(host, "127.")
}

// ---------------------------------------------------------------------------
// helpers

func unparen(e ast.Expr) ast.Expr {
	for {
		p, ok := e.(*ast.ParenExpr)
		if !ok {
			return e
		}
		e = p.X
	}
}

func shortType(t types.Type) string {
	return types.TypeString(t, func(p *types.Package) string { return p.Name() })
}

// dedupeAccesses collapses identical evidence while keeping every distinct site,
// so citations stay specific and aggregation can still merge modes.
func dedupeAccesses(in []ir.Access) []ir.Access {
	seen := map[string]bool{}
	out := make([]ir.Access, 0, len(in))
	for _, a := range in {
		key := a.Node + "|" + a.Mode + "|" + a.Site + "|" + a.Via
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, a)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Node != out[j].Node {
			return out[i].Node < out[j].Node
		}
		if out[i].Site != out[j].Site {
			return out[i].Site < out[j].Site
		}
		return out[i].Mode < out[j].Mode
	})
	return out
}

func sortUnique(in []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}
