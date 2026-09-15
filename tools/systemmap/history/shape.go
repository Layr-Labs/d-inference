package history

import (
	"fmt"
	"sort"

	"github.com/eigeninference/d-inference/tools/systemmap/assemble"
	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/extract"
	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
)

// NodeMeta is a dependency node as one snapshot saw it. The category and group
// travel with it because a node the service has since deleted is absent from
// today's graph, and the page still has to know which boundary to draw it in.
type NodeMeta struct {
	ID       string `json:"id"`
	Category string `json:"category"`
	Group    string `json:"group"`
	Label    string `json:"label"`
}

// RouteMeta is an endpoint as one snapshot saw it, keyed the way the page keys a
// route: "METHOD path".
//
// Namespace, group and auth class travel with it for the same reason a node's
// boundary does. An endpoint that has since been deleted has to be drawn inside
// the namespace it belonged to, or the picture would answer "what did this service
// look like in April" by leaving out the parts of April that did not survive.
type RouteMeta struct {
	Key       string `json:"key"`
	Namespace string `json:"ns"`
	Group     string `json:"group"`
	Auth      string `json:"auth"`
}

// Link is one drawn wire: an endpoint, the state it reaches, and what it does to
// it. This is the same pair the page draws — one per (route, dependency) — so a
// snapshot's link count is the number of lines the picture had.
type Link struct {
	Route string `json:"route"`
	Node  string `json:"node"`
	Mode  string `json:"mode"`
}

// Fidelity is how much of a snapshot the current overlay could still account for.
// It is recorded per snapshot and shown in the page, because the honest reading of
// an early point is "this is what today's overlay can still explain of it", and a
// slider that hid this would make deleted subsystems look like a system that did
// less.
type Fidelity struct {
	// Unmapped counts struct fields an endpoint reaches that no node explains —
	// almost always state whose subsystem was later deleted, so its overlay entry
	// went with it.
	Unmapped int `json:"unmapped"`
	// Unlabeled and Unclassified count derived nodes the overlay cannot name or
	// place. Both mean the picture drew something it could not describe.
	Unlabeled    int `json:"unlabeled"`
	Unclassified int `json:"unclassified"`
}

// There is deliberately no count of packages that failed to type-check, which is the
// one thing here that would not be a curation gap. It cannot be non-zero: extract.Go
// refuses to return a partially loaded program at all, so a commit either yields a
// whole shape or yields none and is recorded in Timeline.Failed. Every field above is
// a question about today's overlay against an old commit; a hole in the extraction is
// a missing point, not a lossy one.

// Shape is one point on the timeline: the endpoints, the state, and the wires
// between them, plus how much of it the overlay explained.
type Shape struct {
	Rev      string      `json:"rev"`
	Date     string      `json:"date"`
	Subject  string      `json:"subject"`
	Module   string      `json:"module"`
	Prefix   string      `json:"prefix"`
	Routes   []RouteMeta `json:"routes"`
	Nodes    []NodeMeta  `json:"nodes"`
	Links    []Link      `json:"links"`
	Tables   int         `json:"tables"`
	Fidelity Fidelity    `json:"fidelity"`
}

// Snapshot derives one point from a checkout. overlay is the *current* overlay's
// bytes: there is only ever one curated description, and a snapshot borrows it
// after its package prefix has been translated to that commit's.
//
// The prose pipeline is deliberately not run. Prose is generated against today's
// facts, its absence is drift rather than a shape difference, and a timeline is a
// question about structure — so a snapshot is the extractor and the assembler,
// and nothing that would make one point's shape depend on how well it was written
// up.
func Snapshot(root string, overlay []byte, routePkg, rev, date, subject string) (*Shape, error) {
	lay, err := Detect(root, routePkg)
	if err != nil {
		return nil, err
	}
	retargeted, err := Retarget(overlay, prefixOf(routePkg), lay.Prefix)
	if err != nil {
		return nil, err
	}
	cfg, err := config.Decode(retargeted, lay.Module, fmt.Sprintf("overlay retargeted to %s at %s", lay.Prefix, rev))
	if err != nil {
		return nil, err
	}

	rep := report.New()
	svc, prog, err := extract.Go(lay.Dir, cfg, rep)
	if err != nil {
		return nil, err
	}
	graph := assemble.Build(svc, prog, cfg, rep, assemble.Options{Revision: rev})

	sh := &Shape{
		Rev: rev, Date: date, Subject: subject,
		Module: lay.Module, Prefix: lay.Prefix,
		Tables: len(graph.Tables),
		Fidelity: Fidelity{
			Unmapped:     len(rep.UnmappedFields),
			Unlabeled:    len(rep.MissingLabels),
			Unclassified: len(rep.Unclassified),
		},
	}
	for _, r := range graph.Routes {
		sh.Routes = append(sh.Routes, RouteMeta{
			Key: r.Method + " " + r.Path, Namespace: r.Namespace, Group: r.Group, Auth: r.Auth,
		})
	}
	for id, n := range graph.Nodes {
		sh.Nodes = append(sh.Nodes, NodeMeta{ID: id, Category: n.Category, Group: n.Group, Label: n.Label})
	}
	sh.Links = wires(graph.Routes, graph.StateAccess)
	// Map iteration and walk order are not the timeline's business: two snapshots
	// must differ only where the service differs, or every point would report
	// churn against its neighbour.
	sort.Slice(sh.Routes, func(i, j int) bool { return sh.Routes[i].Key < sh.Routes[j].Key })
	sort.Slice(sh.Nodes, func(i, j int) bool { return sh.Nodes[i].ID < sh.Nodes[j].ID })
	sort.Slice(sh.Links, func(i, j int) bool {
		if sh.Links[i].Route != sh.Links[j].Route {
			return sh.Links[i].Route < sh.Links[j].Route
		}
		if sh.Links[i].Node != sh.Links[j].Node {
			return sh.Links[i].Node < sh.Links[j].Node
		}
		return sh.Links[i].Mode < sh.Links[j].Mode
	})
	return sh, nil
}

// wires is one snapshot's drawn associations.
//
// The graph's edges are aggregated per (namespace, dependency) and carry the routes
// they cover; the page draws one wire per route in that list, so the timeline counts
// what the page draws rather than what the IR stores.
//
// And it colours them the way the page's `epMode` does: an endpoint's own derived
// mode, falling back to its namespace's aggregate only where the endpoint has none.
// Taking the aggregate everywhere recorded 98 of the coordinator's then-976 wires as
// read-write where the endpoint only reads — so returning the slider to the head
// revision repainted a tenth of the picture, which is the bug this function's shape
// exists to prevent coming back. The total has moved since; the ratio is the point.
func wires(routes []*ir.Endpoint, access []*ir.Edge) []Link {
	own := make(map[string]map[string]string, len(routes))
	for _, r := range routes {
		own[r.Method+" "+r.Path] = r.DepModes
	}
	var out []Link
	for _, e := range access {
		for _, r := range e.Routes {
			mode := e.Mode
			if m, ok := own[r][e.Dependency]; ok && m != "" {
				mode = m
			}
			out = append(out, Link{Route: r, Node: e.Dependency, Mode: mode})
		}
	}
	return out
}

// prefixOf is the overlay's own package prefix, read off the route table package
// so the translation is expressed against the current map rather than a constant.
func prefixOf(routePkg string) string {
	for i := 0; i < len(routePkg); i++ {
		if routePkg[i] == '/' {
			return routePkg[:i+1]
		}
	}
	return ""
}
