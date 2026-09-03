// Package assemble merges extracted source evidence with the curated overlay
// into the final graph, and records every place the two disagree.
package assemble

import (
	"fmt"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/extract"
	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
)

// maxCitations caps the sites listed per edge. The full evidence set is
// reproducible by rerunning the generator; the artifact only needs enough to
// point a reader at the code.
const maxCitations = 6

// buildGroups derives the sub-boundaries: one per namespace around that
// namespace's endpoints, one per category around that category's nodes. Each
// group names the cluster it sits inside, which it inherits from the service or
// the category — so a namespace or category added later is a new sub-boundary
// automatically, and the renderer never learns a taxonomy.
func buildGroups(g *ir.Graph, cfg *config.Config) {
	clusterOfService := map[string]string{}
	for _, svc := range g.Services {
		clusterOfService[svc.ID] = svc.ID
	}
	for _, ep := range g.Routes {
		id := "ns:" + ep.Namespace
		ep.Group = id
		grp, ok := g.Groups[id]
		if !ok {
			grp = &ir.Group{ID: id, Cluster: clusterOfService[ep.Service], Title: ep.Namespace, Kind: "namespace"}
			g.Groups[id] = grp
		}
		grp.Members++
	}
	for _, id := range sortedKeys(g.Nodes) {
		node := g.Nodes[id]
		gid := "cat:" + node.Category
		node.Group = gid
		grp, ok := g.Groups[gid]
		if !ok {
			cat := cfg.Categories[node.Category]
			grp = &ir.Group{ID: gid, Cluster: cat.Cluster, Title: cat.Title, Kind: "category",
				Color: cat.Color, Desc: cat.Desc}
			if grp.Title == "" {
				grp.Title = node.Category
			}
			g.Groups[gid] = grp
		}
		grp.Members++
	}
}

// buildTables publishes the derived table definitions and links each one to its
// dependency node, so clicking a `pg.*` node can show the columns source actually
// declares. A `pg.*` node with no CREATE TABLE anywhere in source is drift: the
// map would be claiming a table the service never creates.
func buildTables(g *ir.Graph, svc *extract.Service, cfg *config.Config, rep *report.Report, revision string) {
	for name, table := range svc.Schema {
		for i := range table.Columns {
			table.Columns[i].URL = blobURL(cfg, revision, table.Columns[i].Site)
		}
		for i := range table.Constraints {
			table.Constraints[i].URL = blobURL(cfg, revision, table.Constraints[i].Site)
		}
		for i := range table.DDL {
			table.DDL[i].URL = blobURL(cfg, revision, table.DDL[i].Site)
		}
		if _, ok := g.Nodes["pg."+name]; ok {
			table.Node = "pg." + name
		}
		g.Tables[name] = table
	}
	for _, id := range sortedKeys(g.Nodes) {
		name, ok := strings.CutPrefix(id, "pg.")
		if !ok {
			continue
		}
		if _, ok := g.Tables[name]; !ok {
			rep.AddUndefinedTable(fmt.Sprintf("`%s` — no `CREATE TABLE %s` exists in analyzed source", id, name))
		}
	}
}

// Options carry everything not derived from source.
type Options struct {
	Revision    string
	OverlayPath string
}

// Build produces the graph.
func Build(svc *extract.Service, prog *extract.Program, cfg *config.Config, rep *report.Report, opt Options) *ir.Graph {
	g := &ir.Graph{
		Revision: opt.Revision,
		Generator: ir.Generator{
			Tool:    "tools/systemmap",
			Derived: "routes, middleware chains, authorization gates, dependency nodes, access modes, citations, boundaries",
			Curated: "node labels, namespaces, auth classes, callers, prose",
			Overlay: opt.OverlayPath,
		},
		Clusters:        cfg.Clusters,
		Groups:          map[string]*ir.Group{},
		Categories:      cfg.Categories,
		Labels:          map[string]string{},
		Nodes:           map[string]*ir.Node{},
		Tables:          map[string]*ir.Table{},
		Roles:           cfg.Roles,
		Credentials:     cfg.Credentials,
		CacheSemantics:  cfg.Cache,
		StateModeLegend: ir.ModeLegend,
		DepDocs:         cfg.DepDocs,
		CategoryDocs:    cfg.CategoryDocs,
	}
	endpoints := buildEndpoints(svc, prog, cfg, rep, opt)
	g.Routes = endpoints
	g.Services = []*ir.Service{{
		ID:       cfg.Service.ID,
		Title:    cfg.Service.Title,
		Language: cfg.Service.Language,
		Root:     cfg.Service.Root,
		Routes:   len(endpoints),
	}}

	g.StateAccess = buildEdges(endpoints)
	buildNodes(g, cfg, rep, svc.Schema)
	buildGroups(g, cfg)
	buildTables(g, svc, cfg, rep, opt.Revision)
	g.StateCoverage = coverage(g.StateAccess)
	checkClusters(g, cfg, rep)
	checkProse(g, cfg, rep)
	checkDeclaredEndpoints(prog, cfg, rep)
	g.Generator.OverlayComplete = rep.Clean()
	return g
}

func buildEndpoints(svc *extract.Service, prog *extract.Program, cfg *config.Config, rep *report.Report, opt Options) []*ir.Endpoint {
	out := make([]*ir.Endpoint, 0, len(svc.Routes))
	for i, ev := range svc.Routes {
		key := ev.Method + " " + ev.Path
		ep := &ir.Endpoint{
			ID:             i + 1,
			Service:        cfg.Service.ID,
			Method:         ev.Method,
			Path:           ev.Path,
			RegisteredPath: ev.Registered,
			Handler:        ev.Handler,
			Middleware:     ev.Middleware,
			Gates:          ev.Gates,
			RouteFile:      ev.File,
			RouteLine:      ev.Line,
			Evidence:       ev.Accesses,
		}
		if ep.Middleware == nil {
			ep.Middleware = []string{}
		}
		if ep.Gates == nil {
			ep.Gates = []string{}
		}

		ns, nsOK := cfg.Namespace(ev.Method, ev.Path)
		ep.Namespace = ns
		auth, detail, authOK := cfg.Auth(ev.Middleware, ev.Gates, ev.Handler)
		ep.Auth, ep.AuthDetail = auth, detail
		if !nsOK || !authOK {
			missing := "namespace"
			if nsOK {
				missing = "auth class"
			}
			rep.AddUnclassified(fmt.Sprintf("`%s` (%s) — no %s rule matches (middleware %v, gates %v)",
				key, ev.Handler, missing, ev.Middleware, ev.Gates))
		}

		ep.Source = handlerSource(prog, ev)
		ep.SourceURL = blobURL(cfg, opt.Revision, ep.Source)
		ep.RouteURL = blobURL(cfg, opt.Revision, fmt.Sprintf("%s:%d", ep.RouteFile, ep.RouteLine))

		if overlay, ok := cfg.Routes[key]; ok {
			ep.Description = overlay.Description
			ep.Details = overlay.Details
			ep.Callers = overlay.Callers
		} else {
			rep.AddMissingProse(fmt.Sprintf("`%s` → `%s` (%s:%d)", key, ev.Handler, ep.RouteFile, ep.RouteLine))
		}
		if ep.Callers == nil {
			ep.Callers = []string{}
		}
		if len(ep.Callers) > 0 {
			ep.Caller = ep.Callers[0]
		}
		ep.Dependencies = nodeList(ev.Accesses)
		ep.DepModes = map[string]string{}
		for _, a := range ev.Accesses {
			ep.DepModes[a.Node] = mergeMode(ep.DepModes[a.Node], a.Mode)
		}
		out = append(out, ep)
	}
	return out
}

// handlerSource locates the handler's declaration, falling back to the
// registration site for inline handlers.
func handlerSource(prog *extract.Program, ev *extract.RouteEvidence) string {
	for _, sym := range ev.Entry {
		if sym.Name == ev.Handler && sym.Decl != nil {
			return prog.PosRef(sym.Decl.Pos())
		}
	}
	return fmt.Sprintf("%s:%d", ev.File, ev.Line)
}

func blobURL(cfg *config.Config, revision, ref string) string {
	if cfg.Repo.Remote == "" || ref == "" {
		return ""
	}
	file, line := ref, ""
	if i := strings.LastIndex(ref, ":"); i > 0 {
		file, line = ref[:i], ref[i+1:]
	}
	url := strings.TrimSuffix(cfg.Repo.Remote, "/") + "/blob/" + revision + "/" + file
	if line != "" {
		url += "#L" + line
	}
	return url
}

func nodeList(accesses []ir.Access) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, a := range accesses {
		if seen[a.Node] {
			continue
		}
		seen[a.Node] = true
		out = append(out, a.Node)
	}
	sort.Strings(out)
	return out
}

// buildEdges aggregates per-endpoint evidence into namespace→node associations.
func buildEdges(endpoints []*ir.Endpoint) []*ir.Edge {
	type agg struct {
		edge      *ir.Edge
		modes     string
		routes    map[string]bool
		citations map[string]bool
		vias      map[string]string // symbol → mode, for the derived reason
	}
	byKey := map[string]*agg{}
	var order []string
	for _, ep := range endpoints {
		for _, a := range ep.Evidence {
			key := ep.Namespace + "\x00" + a.Node
			cur, ok := byKey[key]
			if !ok {
				cur = &agg{
					edge:      &ir.Edge{Namespace: ep.Namespace, Dependency: a.Node},
					routes:    map[string]bool{},
					citations: map[string]bool{},
					vias:      map[string]string{},
				}
				byKey[key] = cur
				order = append(order, key)
			}
			cur.modes = mergeMode(cur.modes, a.Mode)
			cur.routes[ep.Method+" "+ep.Path] = true
			cur.citations[a.Site] = true
			cur.vias[a.Via] = mergeMode(cur.vias[a.Via], a.Mode)
		}
	}
	sort.Strings(order)
	out := make([]*ir.Edge, 0, len(order))
	for _, key := range order {
		cur := byKey[key]
		cur.edge.Mode = cur.modes
		cur.edge.Routes = sortedKeys(cur.routes)
		cur.edge.Citations = limit(sortedKeys(cur.citations), maxCitations)
		cur.edge.Reason = reason(cur.modes, cur.vias)
		out = append(out, cur.edge)
	}
	return out
}

// reason states, in one sentence, which symbols evidenced the association.
func reason(mode string, vias map[string]string) string {
	names := sortedKeys(vias)
	var reads, writes []string
	for _, name := range names {
		switch vias[name] {
		case ir.ModeRead:
			reads = append(reads, name)
		case ir.ModeWrite:
			writes = append(writes, name)
		default:
			reads = append(reads, name)
			writes = append(writes, name)
		}
	}
	parts := []string{}
	if len(reads) > 0 {
		parts = append(parts, "read via "+strings.Join(limit(reads, 3), ", "))
	}
	if len(writes) > 0 {
		parts = append(parts, "written via "+strings.Join(limit(writes, 3), ", "))
	}
	if len(parts) == 0 {
		return "No evidencing symbol recorded."
	}
	switch mode {
	case ir.ModeRead:
		parts = parts[:1]
	case ir.ModeWrite:
		parts = parts[len(parts)-1:]
	}
	return strings.ToUpper(parts[0][:1]) + strings.Join(parts, "; ")[1:] + "."
}

// buildNodes materializes the node set from evidence plus the overlay's declared
// labels, and reports both unlabeled derived nodes and declared-but-unreached
// ones.
// identityOrigins records which mapping table gives each node its identity. It is
// read straight out of the overlay and the derived schema — no judgement — and it
// separates two questions the map otherwise conflates: whether source *evidences* a
// node (Reached) and how much of the node's *name* a person invented. A `pg.*` node
// is named by the CREATE TABLE source issues; a host, remote endpoint or protocol
// message node is a curated name bound to a literal the compiler found; a field,
// type or function node is a curated name bound to a symbol.
func identityOrigins(cfg *config.Config, schema map[string]*ir.Table) map[string][]string {
	kinds := map[string]map[string]bool{}
	mark := func(node, kind string) {
		// Sentinels are decisions not to draw a node ("@skip", "@sql", "@through"),
		// so they name nothing.
		if node == "" || strings.HasPrefix(node, "@") {
			return
		}
		if kinds[node] == nil {
			kinds[node] = map[string]bool{}
		}
		kinds[node][kind] = true
	}
	for _, node := range cfg.Deps.Fields {
		mark(node, "fields")
	}
	// A package-wide default is a field rule with a wider mouth, not a third kind.
	for _, node := range cfg.Deps.PackageDefault {
		mark(node, "fields")
	}
	for _, node := range cfg.Deps.Types {
		mark(node, "types")
	}
	for _, node := range cfg.Deps.Functions {
		mark(node, "functions")
	}
	for _, node := range cfg.Deps.Hosts {
		mark(node, "hosts")
	}
	for _, byPkg := range cfg.Deps.Endpoints {
		for _, node := range byPkg {
			mark(node, "endpoints")
		}
	}
	for _, byPkg := range cfg.Deps.Messages {
		for _, node := range byPkg {
			mark(node, "messages")
		}
	}
	for name := range schema {
		mark("pg."+name, "sql")
	}
	out := map[string][]string{}
	for node, set := range kinds {
		out[node] = sortedKeys(set)
	}
	return out
}

func buildNodes(g *ir.Graph, cfg *config.Config, rep *report.Report, schema map[string]*ir.Table) {
	origins := identityOrigins(cfg, schema)
	reached := map[string]bool{}
	for _, edge := range g.StateAccess {
		reached[edge.Dependency] = true
	}
	ids := map[string]bool{}
	for id := range reached {
		ids[id] = true
	}
	for id := range cfg.Labels {
		ids[id] = true
	}
	for _, id := range sortedKeys(ids) {
		label, ok := cfg.Labels[id]
		if !ok {
			label = autoLabel(id)
			if label == "" {
				rep.MissingLabel(id)
				label = id
			}
		}
		category := id
		if i := strings.Index(id, "."); i > 0 {
			category = id[:i]
		}
		if _, known := cfg.Categories[category]; !known {
			rep.MissingLabel(id + " (unknown category " + category + ")")
		}
		g.Labels[id] = label
		g.Nodes[id] = &ir.Node{ID: id, Category: category, Label: label,
			Derived: reached[id], Reached: reached[id], NamedBy: origins[id]}
		if !reached[id] {
			rep.AddUnreachedNode(fmt.Sprintf("`%s` — declared in `labels` but no endpoint reaches it", id))
		}
	}
}

// autoLabel names the nodes whose identity source already states: a Postgres
// node is its table.
func autoLabel(id string) string {
	if table, ok := strings.CutPrefix(id, "pg."); ok {
		return table
	}
	return ""
}

func coverage(edges []*ir.Edge) ir.Coverage {
	cov := ir.Coverage{ModeCounts: map[string]int{}}
	for _, e := range edges {
		cov.TotalAssociations++
		cov.ModeCounts[e.Mode]++
		switch {
		case strings.HasPrefix(e.Dependency, "pg."):
			cov.PostgresAssociations++
		case strings.HasPrefix(e.Dependency, "mem."):
			cov.InMemoryAssociations++
		}
		if e.Mode == "" || e.Mode == "?" {
			cov.Ambiguous++
			continue
		}
		cov.Classified++
	}
	return cov
}

// checkClusters verifies that the graph can be drawn: every extracted service
// and every node category names a declared cluster, and every declared cluster
// is used. A cluster that nothing places nodes in would render as an empty
// boundary; a category without one would leave its nodes floating outside every
// boundary — which is exactly the claim the picture must not make.
func checkClusters(g *ir.Graph, cfg *config.Config, rep *report.Report) {
	used := map[string]bool{}
	for _, svc := range g.Services {
		used[svc.ID] = true
		if _, ok := cfg.Clusters[svc.ID]; !ok {
			rep.AddBadCluster(fmt.Sprintf("`clusters[%q]` — service `%s` has no cluster to draw its process boundary",
				svc.ID, svc.Title))
		}
	}
	for _, name := range sortedKeys(cfg.Categories) {
		cluster := cfg.Categories[name].Cluster
		if cluster == "" {
			rep.AddBadCluster(fmt.Sprintf("`categories[%q].cluster` — unset, so its nodes have no boundary", name))
			continue
		}
		used[cluster] = true
		if _, ok := cfg.Clusters[cluster]; !ok {
			rep.AddBadCluster(fmt.Sprintf("`categories[%q].cluster = %q` — no such cluster is declared", name, cluster))
		}
	}
	for _, id := range sortedKeys(cfg.Clusters) {
		if !used[id] {
			rep.AddBadCluster(fmt.Sprintf("`clusters[%q]` — declared but no service or category places nodes in it", id))
		}
	}
}

// checkProse reports overlay entries that no longer match source.
func checkProse(g *ir.Graph, cfg *config.Config, rep *report.Report) {
	live := map[string]bool{}
	for _, ep := range g.Routes {
		live[ep.Method+" "+ep.Path] = true
	}
	for key := range cfg.Routes {
		if !live[key] {
			rep.AddStaleProse(fmt.Sprintf("`routes[%q]` — no such route is registered", key))
		}
	}
	// A node with no prose is a boundary the picture draws and cannot explain.
	// The label alone is a name, not a claim about what the state is, who mutates
	// it, or whether it survives a restart — so prose is required, in both
	// directions.
	for _, id := range sortedKeys(g.Nodes) {
		if _, ok := cfg.DepDocs[id]; !ok {
			rep.AddUndocumented(fmt.Sprintf("`depDocs[%q]` — node is drawn but has no overview/represents/concurrency prose", id))
		}
	}
	for id := range cfg.DepDocs {
		if _, ok := g.Nodes[id]; !ok {
			rep.AddStaleProse(fmt.Sprintf("`depDocs[%q]` — no such dependency node", id))
		}
	}
	for id := range cfg.Cache {
		if _, ok := g.Nodes[id]; !ok {
			rep.AddStaleProse(fmt.Sprintf("`cacheSemantics[%q]` — no such dependency node", id))
		}
	}
}

// checkDeclaredEndpoints verifies that every remote endpoint the overlay claims
// still appears as a literal in the client package. Reachability from an HTTP
// endpoint is not required — some of these surfaces are driven by background
// workers — so this is what keeps those claims provable.
func checkDeclaredEndpoints(prog *extract.Program, cfg *config.Config, rep *report.Report) {
	for pkgRel, table := range cfg.Deps.Endpoints {
		literals := prog.StringLiterals(cfg.ImportPath(pkgRel))
		if len(literals) == 0 {
			rep.AddStaleProse(fmt.Sprintf("`deps.endpoints[%q]` — package has no loaded source", pkgRel))
			continue
		}
		for literal := range table {
			if !literals[literal] {
				rep.AddStaleProse(fmt.Sprintf("`deps.endpoints[%q][%q]` — literal no longer appears in %s",
					pkgRel, literal, pkgRel))
			}
		}
	}
}

func mergeMode(a, b string) string {
	switch {
	case a == "":
		return b
	case b == "":
		return a
	case a == b:
		return a
	}
	return ir.ModeBoth
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func limit(in []string, n int) []string {
	if len(in) <= n {
		return in
	}
	return in[:n]
}
