package extract

import (
	"fmt"
	"go/ast"
	"go/types"
	"strconv"
	"strings"

	"golang.org/x/tools/go/packages"
)

// Route is one registration found in the service's route table.
type Route struct {
	Method     string // "GET"; "ANY" for a bare-path (method-less) pattern
	Path       string
	Registered string // the literal mux pattern, e.g. "GET /v1/models"
	Handler    string // handler func name, or "inline" for a function literal
	Middleware []string

	Entry []*FuncSym   // handler + middleware, the roots of the reachable set
	Lit   *ast.FuncLit // set when the handler is written inline
	LitIn *packages.Package
	File  string
	Line  int
}

// Routes extracts the route table from a registration method, e.g.
// (*api.Server).routes registering onto its `mux` field.
func (p *Program) Routes(pkgPath, typeName, method, muxField string) ([]*Route, error) {
	sym := p.Method(pkgPath, typeName, method)
	if sym == nil {
		return nil, fmt.Errorf("no %s.%s.%s to read routes from", pkgPath, typeName, method)
	}
	info := sym.Pkg.TypesInfo
	var routes []*Route
	var err error
	ast.Inspect(sym.Decl.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel.Name != "HandleFunc" || len(call.Args) != 2 {
			return true
		}
		if !isFieldRef(info, sel.X, muxField) {
			return true
		}
		pattern, ok := stringLit(call.Args[0])
		if !ok {
			err = fmt.Errorf("%s: HandleFunc pattern is not a string literal", p.PosRef(call.Pos()))
			return false
		}
		route := &Route{Registered: pattern}
		route.Method, route.Path = splitPattern(pattern)
		pos := p.Fset.Position(call.Pos())
		route.File = strings.TrimPrefix(strings.TrimPrefix(pos.Filename, p.Root), "/")
		route.Line = pos.Line
		if e := p.unwrap(sym.Pkg, call.Args[1], route); e != nil {
			err = e
			return false
		}
		routes = append(routes, route)
		return true
	})
	if err != nil {
		return nil, err
	}
	return routes, nil
}

// unwrap peels the middleware chain off a registration argument. Middleware is
// recognized structurally — a one-argument call whose signature maps an
// http.HandlerFunc to an http.HandlerFunc — so a new wrapper needs no config.
func (p *Program) unwrap(pkg *packages.Package, expr ast.Expr, route *Route) error {
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return p.unwrap(pkg, e.X, route)
	case *ast.FuncLit:
		route.Handler = "inline"
		route.Lit = e
		route.LitIn = pkg
		return nil
	case *ast.CallExpr:
		fn := funcObject(pkg.TypesInfo, e.Fun)
		if fn == nil || len(e.Args) != 1 || !isMiddleware(fn) {
			// Not a wrapper: the call itself produces the handler (e.g. an
			// http.Handler adapter). Record it as the handler and stop.
			if fn != nil {
				route.Handler = fn.Name()
				if sym := p.DeclOf(fn); sym != nil {
					route.Entry = append(route.Entry, sym)
				}
				return nil
			}
			return fmt.Errorf("%s: unresolvable handler expression for %q", p.PosRef(e.Pos()), route.Registered)
		}
		route.Middleware = append(route.Middleware, fn.Name())
		if sym := p.DeclOf(fn); sym != nil {
			route.Entry = append(route.Entry, sym)
		}
		return p.unwrap(pkg, e.Args[0], route)
	case *ast.SelectorExpr:
		fn := funcObject(pkg.TypesInfo, e)
		if fn == nil {
			return fmt.Errorf("%s: unresolvable handler %q", p.PosRef(e.Pos()), route.Registered)
		}
		route.Handler = fn.Name()
		if sym := p.DeclOf(fn); sym != nil {
			route.Entry = append(route.Entry, sym)
		}
		return nil
	case *ast.Ident:
		fn := funcObject(pkg.TypesInfo, e)
		if fn == nil {
			return fmt.Errorf("%s: unresolvable handler %q", p.PosRef(e.Pos()), route.Registered)
		}
		route.Handler = fn.Name()
		if sym := p.DeclOf(fn); sym != nil {
			route.Entry = append(route.Entry, sym)
		}
		return nil
	}
	return fmt.Errorf("%s: unsupported handler expression %T for %q", p.PosRef(expr.Pos()), expr, route.Registered)
}

// isMiddleware reports whether a function has the http.HandlerFunc →
// http.HandlerFunc shape.
func isMiddleware(fn *types.Func) bool {
	sig, ok := fn.Type().(*types.Signature)
	if !ok || sig.Params().Len() != 1 || sig.Results().Len() != 1 {
		return false
	}
	return isHandlerFunc(sig.Params().At(0).Type()) && isHandlerFunc(sig.Results().At(0).Type())
}

func isHandlerFunc(t types.Type) bool {
	named := namedOf(t)
	if named != nil && named.Obj().Name() == "HandlerFunc" {
		return true
	}
	sig, ok := types.Unalias(t).Underlying().(*types.Signature)
	if !ok || sig.Params().Len() != 2 || sig.Results().Len() != 0 {
		return false
	}
	w := namedOf(sig.Params().At(0).Type())
	r := namedOf(sig.Params().At(1).Type())
	return w != nil && w.Obj().Name() == "ResponseWriter" && r != nil && r.Obj().Name() == "Request"
}

// funcObject resolves an expression that denotes a function or method.
func funcObject(info *types.Info, expr ast.Expr) *types.Func {
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return funcObject(info, e.X)
	case *ast.Ident:
		fn, _ := info.Uses[e].(*types.Func)
		return fn
	case *ast.SelectorExpr:
		fn, _ := info.Uses[e.Sel].(*types.Func)
		return fn
	case *ast.IndexExpr: // generic instantiation
		return funcObject(info, e.X)
	}
	return nil
}

// isFieldRef reports whether expr selects the named field (s.mux).
func isFieldRef(info *types.Info, expr ast.Expr, field string) bool {
	sel, ok := expr.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	if sel.Sel.Name != field {
		return false
	}
	v, ok := info.Uses[sel.Sel].(*types.Var)
	return ok && v.IsField()
}

func stringLit(expr ast.Expr) (string, bool) {
	lit, ok := expr.(*ast.BasicLit)
	if !ok || lit.Kind.String() != "STRING" {
		return "", false
	}
	s, err := strconv.Unquote(lit.Value)
	if err != nil {
		return "", false
	}
	return s, true
}

// splitPattern separates a net/http 1.22 mux pattern into method and path. A
// pattern with no method (the legacy "/v1/" catch-all) matches any method.
func splitPattern(pattern string) (string, string) {
	if i := strings.Index(pattern, " "); i > 0 {
		return pattern[:i], strings.TrimSpace(pattern[i+1:])
	}
	return "ANY", pattern
}
