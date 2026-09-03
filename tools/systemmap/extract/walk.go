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
	dbPos        token.Pos               // the first driver call, for citing a declared table
	declPos      token.Pos               // this function's own declaration
	opaqueSeen   bool                    // unreadable text was found, reported or declared
	opaqueTables map[string]string       // tables named in unreadable text, and where
	textScope    any                     // what the text being walked belongs to; see textScopeFor
	textFresh    bool                    // the current scope is being bound, not appended to
	ctes         map[any]map[string]bool // WITH clauses declared per assembled statement
	frags        []fragment              // table names read out of fragments, settled at body end

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
	if scope, fresh := f.textScopeFor(s); scope != nil {
		f.textScope, f.textFresh = scope, fresh
	}
	f.walkStmt(s)
	f.textScope, f.textFresh = prevScope, prevFresh
}

// textScopeFor names the statement text inside s belongs to, and says whether s
// binds that name afresh rather than appending to it.
//
// An assignment is the strongest answer: a query built up over several lines is
// built into one variable, and `qs[0] += tail` or `s.q += tail` resolve to that
// variable too, so splitting a query across an index or a field does not split its
// scope. Failing that the statement itself is the scope, which is what keeps two
// statements handed straight to the driver — `Exec(ctx, a)` then `Exec(ctx, b)` —
// from sharing one CTE set. Composite statements return nil so that the statements
// nested inside them each answer for themselves.
//
// The second result is what makes a recycled variable safe: `q = <a whole
// statement>` means q now holds a different query, so whatever CTE names the last
// one declared no longer apply. `q += tail` says nothing of the kind.
func (f *fnWalk) textScopeFor(s ast.Stmt) (any, bool) {
	switch x := s.(type) {
	case nil:
		return nil, false
	case *ast.BlockStmt, *ast.IfStmt, *ast.ForStmt, *ast.RangeStmt, *ast.SwitchStmt,
		*ast.TypeSwitchStmt, *ast.CaseClause, *ast.SelectStmt, *ast.CommClause,
		*ast.LabeledStmt:
		return nil, false
	case *ast.AssignStmt:
		fresh := x.Tok == token.ASSIGN || x.Tok == token.DEFINE
		if obj := f.assignTarget(x.Lhs); obj != nil {
			return obj, fresh
		}
		return s, fresh
	}
	return s, false
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
		for _, rhs := range x.Rhs {
			f.visit(rhs, ModeRead)
		}
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
				// `var q = ...` scopes its text the same way an assignment does,
				// per spec rather than per declaration, and binds it afresh.
				prevScope, prevFresh := f.textScope, f.textFresh
				f.textScope, f.textFresh = vs, true
				if obj := f.assignTarget(identExprs(vs.Names)); obj != nil {
					f.textScope = obj
				}
				for _, v := range vs.Values {
					f.visit(v, ModeRead)
				}
				f.textScope, f.textFresh = prevScope, prevFresh
				f.bindSpec(vs)
			}
		}
	case *ast.ReturnStmt:
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
		f.stmt(x.Body)
	case *ast.RangeStmt:
		f.visit(x.X, ModeRead)
		f.bindRange(x)
		f.stmt(x.Body)
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
// scopes the statement text on its right. An assignment with several targets has
// no single one — `_, err := db.Exec(ctx, q)` writes err, not the query — and its
// text is scoped by the statement instead.
func (f *fnWalk) assignTarget(lhs []ast.Expr) types.Object {
	if len(lhs) != 1 {
		return nil
	}
	return f.objOf(baseIdent(lhs[0]))
}

// baseIdent digs out the variable an assignment target is reaching into, so that
// `qs[0]`, `s.q` and `*p` scope their text to the same place a bare `q` would.
// Without it a query whose base statement lands in a slice and whose tail lands in
// `qs[0]` would be read as two unrelated statements.
func baseIdent(e ast.Expr) *ast.Ident {
	for {
		switch x := e.(type) {
		case *ast.Ident:
			return x
		case *ast.ParenExpr:
			e = x.X
		case *ast.StarExpr:
			e = x.X
		case *ast.IndexExpr:
			e = x.X
		case *ast.SelectorExpr:
			return x.Sel
		default:
			return nil
		}
	}
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
			f.visit(el, ModeRead)
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
		f.visit(arg, ModeRead)
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
		for _, acc := range Tables(s) {
			if !f.w.tables[acc.Table] {
				f.w.Rep.UnknownTable(acc.Table, f.w.P.PosRef(pos))
				continue
			}
			f.record("pg."+acc.Table, acc.Mode, pos)
		}
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
