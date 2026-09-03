package extract

import (
	"go/ast"
	"sort"
	"strconv"
)

// Gates lists the authorization checks a route's code performs.
//
// Middleware alone cannot classify a route: several coordinator handlers accept
// the general bearer middleware and then narrow authorization internally
// (`isAdminAuthorized`), and several take no middleware at all and gate entirely
// in the handler (`requirePublishingAPIKey`, `releaseKeyAuthorized`). So gates
// are collected from the handler and middleware bodies outward.
//
// The search is depth-bounded on purpose. A gate is called by the handler or by
// a helper it calls directly; a name matched ten frames deeper would be
// incidental and would misclassify the route. Depth is part of the visit key, so
// this pass is kept separate from the memoized access walk, whose results are
// depth-independent.
func (w *Walker) Gates(entries []*FuncSym) []string {
	type frame struct {
		sym   *FuncSym
		depth int
	}
	queue := make([]frame, 0, len(entries))
	for _, sym := range entries {
		queue = append(queue, frame{sym, 0})
	}
	visited := map[string]bool{}
	found := map[string]bool{}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		if cur.sym == nil || cur.sym.Decl == nil || cur.sym.Decl.Body == nil {
			continue
		}
		key := cur.sym.key() + "#" + strconv.Itoa(cur.depth)
		if visited[key] {
			continue
		}
		visited[key] = true
		info := cur.sym.Pkg.TypesInfo
		ast.Inspect(cur.sym.Decl.Body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			fn := funcObject(info, call.Fun)
			if fn == nil {
				return true
			}
			if w.gates[fn.Name()] {
				found[fn.Name()] = true
			}
			if cur.depth+1 > w.Cfg.GateDepth() {
				return true
			}
			next := w.P.DeclOf(fn)
			if next != nil && next.Pkg != nil && w.Cfg.Traverse(next.Pkg.PkgPath) {
				queue = append(queue, frame{next, cur.depth + 1})
			}
			return true
		})
	}
	out := make([]string, 0, len(found))
	for name := range found {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}
