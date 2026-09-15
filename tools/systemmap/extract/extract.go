package extract

import (
	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
)

// RouteEvidence is one route plus everything derived from its reachable code.
type RouteEvidence struct {
	*Route
	Accesses []ir.Access
	Gates    []string
}

// Service is the extractor's output for one service.
type Service struct {
	Routes []*RouteEvidence
	// Schema is the derived definition of every table the service declares,
	// keyed by table name.
	Schema map[string]*ir.Table
}

// Go extracts a Go service: load and type-check it, read its route table, then
// walk each route's reachable code for state access and authorization gates.
func Go(root string, cfg *config.Config, rep *report.Report) (*Service, *Program, error) {
	patterns := cfg.AnalyzePatterns()
	prog, err := Load(root, cfg.Module(), patterns)
	if err != nil {
		return nil, nil, err
	}
	table := cfg.Service.RouteTable
	routes, err := prog.Routes(cfg.ImportPath(table.Package), table.Type, table.Method, table.Mux)
	if err != nil {
		return nil, nil, err
	}
	walker := NewWalker(prog, cfg, rep)
	svc := &Service{Schema: prog.SchemaDefinitions()}
	for _, route := range routes {
		ev := &RouteEvidence{Route: route}
		// Route.Entry holds the roots in request order — outermost middleware first,
		// handler last — so chaining the blocks in that order is what makes the
		// route's access sequence read as the order a *reader* meets them, rather than
		// as several independent numberings interleaved.
		//
		// The reader's order and not the runtime's: a whole frame is shifted, so a
		// middleware's unwind work is numbered with the middleware even though it runs
		// after everything in the handler (`defer s.decInflight()` in the coordinator's
		// drain gate is exactly that). The step carries `deferred` where that is true,
		// which is the strongest thing a derivation that never runs the program can say.
		//
		// An inline handler literal is chained *last* for the same reason. When a
		// route is registered as `mux.HandleFunc(p, s.requireAuth(func(w, r){...}))`
		// the unwrap yields both — the middleware in Entry and the literal in Lit —
		// and the literal is the innermost of them: it is the handler the middleware
		// wraps, so its accesses come after theirs and not before.
		var blocks [][]ir.Access
		for _, entry := range route.Entry {
			blocks = append(blocks, walker.Func(entry).Accesses)
		}
		if route.Lit != nil {
			blocks = append(blocks, walker.Lit(route.LitIn, route.Lit, table.Type+"."+table.Method).Accesses)
		}
		ev.Accesses = chainAccesses(blocks)
		ev.Gates = walker.Gates(route.Entry)
		svc.Routes = append(svc.Routes, ev)
	}
	walker.AuditAssembled()
	return svc, prog, nil
}
