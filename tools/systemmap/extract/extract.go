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
		if route.Lit != nil {
			ev.Accesses = append(ev.Accesses, walker.Lit(route.LitIn, route.Lit, table.Type+"."+table.Method).Accesses...)
		}
		for _, entry := range route.Entry {
			ev.Accesses = append(ev.Accesses, walker.Func(entry).Accesses...)
		}
		ev.Accesses = dedupeAccesses(ev.Accesses)
		ev.Gates = walker.Gates(route.Entry)
		svc.Routes = append(svc.Routes, ev)
	}
	return svc, prog, nil
}
