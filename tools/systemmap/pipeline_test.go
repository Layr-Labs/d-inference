package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/tools/systemmap/assemble"
	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/extract"
	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/render"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
)

// fixtureRevision is a fixed 40-hex revision, so the artifact a test compares is
// not a function of the checkout it ran in.
const fixtureRevision = "0123456789abcdef0123456789abcdef01234567"

// buildFixture runs the whole pipeline over testdata/fixture: a real miniature
// service, type-checked by go/packages exactly as the coordinator is. The
// optional mutators break the loaded overlay on purpose, which is how the drift
// checks are proved to fire.
func buildFixture(t *testing.T, mutate ...func(*config.Config)) (*ir.Graph, *report.Report) {
	t.Helper()
	root, err := filepath.Abs("testdata/fixture")
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(filepath.Join(root, "overlay.json"), "svcfix.test")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range mutate {
		fn(cfg)
	}
	rep := report.New()
	svc, prog, err := extract.Go(root, cfg, rep)
	if err != nil {
		t.Fatal(err)
	}
	graph := assemble.Build(svc, prog, cfg, rep, assemble.Options{
		Revision:    fixtureRevision,
		OverlayPath: "overlay.json",
	})
	return graph, rep
}

func endpoints(g *ir.Graph) map[string]*ir.Endpoint {
	out := map[string]*ir.Endpoint{}
	for _, ep := range g.Routes {
		out[ep.Method+" "+ep.Path] = ep
	}
	return out
}

// TestFixtureRoutes pins everything the extractor derives per route: the mux
// pattern, the middleware chain it was wrapped in, the gates its code calls, and
// the state that code reaches through interface dispatch, a mutually recursive
// helper, a package constant and a goroutine closure.
func TestFixtureRoutes(t *testing.T) {
	g, _ := buildFixture(t)
	want := map[string]struct {
		handler    string
		middleware []string
		gates      []string
		namespace  string
		auth       string
		deps       []string
	}{
		"GET /v1/models": {
			handler:    "handleModels",
			middleware: []string{"withAuth"},
			gates:      []string{},
			namespace:  "Public",
			auth:       "Bearer",
			deps:       []string{"ext.icons", "mem.aliases", "mem.cache", "pg.models"},
		},
		"GET /v1/aliases": {
			handler:    "handleAliases",
			middleware: []string{"withAuth"},
			gates:      []string{},
			namespace:  "Public",
			auth:       "Bearer",
			deps:       []string{"mem.aliases", "mem.cache", "mem.flight"},
		},
		"POST /v1/usage": {
			handler:    "handleUsage",
			middleware: []string{},
			gates:      []string{},
			namespace:  "Public",
			auth:       "Public",
			deps:       []string{"ext.opaque", "mem.inflight", "pg.models", "pg.usage"},
		},
		"GET /v1/admin/stats": {
			handler:    "handleAdminStats",
			middleware: []string{"withAuth"},
			gates:      []string{"isAdmin"},
			namespace:  "Admin",
			auth:       "Admin",
			deps:       []string{"mem.admins", "pg.usage"},
		},
		"ANY /legacy/": {
			handler:    "inline",
			middleware: []string{},
			gates:      []string{},
			namespace:  "Legacy",
			auth:       "Public",
			deps:       []string{"mem.cache"},
		},
	}
	got := endpoints(g)
	if len(got) != len(want) {
		t.Fatalf("extracted %d routes, want %d: %v", len(got), len(want), got)
	}
	for key, exp := range want {
		ep, ok := got[key]
		if !ok {
			t.Errorf("route %q not extracted", key)
			continue
		}
		if ep.Handler != exp.handler {
			t.Errorf("%s handler = %q, want %q", key, ep.Handler, exp.handler)
		}
		if !reflect.DeepEqual(ep.Middleware, exp.middleware) {
			t.Errorf("%s middleware = %v, want %v", key, ep.Middleware, exp.middleware)
		}
		if !reflect.DeepEqual(ep.Gates, exp.gates) {
			t.Errorf("%s gates = %v, want %v", key, ep.Gates, exp.gates)
		}
		if ep.Namespace != exp.namespace {
			t.Errorf("%s namespace = %q, want %q", key, ep.Namespace, exp.namespace)
		}
		if ep.Auth != exp.auth {
			t.Errorf("%s auth = %q, want %q", key, ep.Auth, exp.auth)
		}
		if !reflect.DeepEqual(ep.Dependencies, exp.deps) {
			t.Errorf("%s dependencies = %v, want %v", key, ep.Dependencies, exp.deps)
		}
	}
}

// TestFixtureNoDrift asserts a complete overlay produces an empty report. Every
// other fixture test would still pass with drift, so this is the one that keeps
// the -check contract meaningful.
func TestFixtureNoDrift(t *testing.T) {
	_, rep := buildFixture(t)
	if !rep.Clean() {
		t.Fatalf("fixture overlay is complete but drift was reported: %s\n\n%s", rep.Counts(), rep.Markdown())
	}
}

// TestFixtureAbsorbedConcurrentState is the regression for the state-holder
// check. fetch.Client carries a mutex and a counter, and `deps.packageDefault`
// would happily swallow it: without the check, adding stateful machinery to a
// defaulted package produces no build failure and no node, and the map quietly
// understates the system. Dropping the overlay's claim about the struct must
// name it.
func TestFixtureAbsorbedConcurrentState(t *testing.T) {
	_, rep := buildFixture(t, func(cfg *config.Config) {
		delete(cfg.Deps.Fields, "fetch:Client.mu")
		delete(cfg.Deps.Fields, "fetch:Client.inflight")
	})
	holder, ok := rep.AbsorbedTypes["fetch:Client"]
	if !ok {
		t.Fatalf("undeclared concurrent state was absorbed silently: %s", rep.Counts())
	}
	if holder.Field != "mu" || holder.Via != "deps.packageDefault" {
		t.Errorf("holder = %+v, want the mu field absorbed by deps.packageDefault", holder)
	}
	if !strings.Contains(rep.Markdown(), "`fetch:Client` — concurrent state") {
		t.Error("report does not name the absorbed type")
	}

	// A deliberate decision clears it, whichever form the decision takes: the
	// check asks that someone looked, not that the answer is a node.
	_, rep = buildFixture(t, func(cfg *config.Config) {
		delete(cfg.Deps.Fields, "fetch:Client.mu")
		delete(cfg.Deps.Fields, "fetch:Client.inflight")
		cfg.Deps.Types["fetch:Client"] = "@skip"
	})
	if _, ok := rep.AbsorbedTypes["fetch:Client"]; ok {
		t.Error("an explicit @skip did not clear the state-holder finding")
	}
}

// TestFixtureUndocumentedNode covers the prose requirement: a node the graph
// draws with only a label is a boundary the page cannot explain.
func TestFixtureUndocumentedNode(t *testing.T) {
	_, rep := buildFixture(t, func(cfg *config.Config) {
		delete(cfg.DepDocs, "mem.cache")
	})
	if len(rep.UndocumentedN) != 1 || !strings.Contains(rep.UndocumentedN[0], "mem.cache") {
		t.Errorf("undocumented nodes = %v, want mem.cache reported", rep.UndocumentedN)
	}
	if rep.Clean() {
		t.Error("report is clean despite an undocumented node")
	}
}

// TestFixtureCycleEvidence is the regression for memoizing an incomplete result.
// Both routes enter the expandAliases/resolveAlias cycle, at different points; if
// the frame that saw the back edge memoized its truncated result, whichever route
// ran second would be missing half the cycle's state.
func TestFixtureCycleEvidence(t *testing.T) {
	g, _ := buildFixture(t)
	for _, key := range []string{"GET /v1/models", "GET /v1/aliases"} {
		ep := endpoints(g)[key]
		if ep == nil {
			t.Fatalf("route %q not extracted", key)
		}
		for _, node := range []string{"mem.aliases", "mem.cache"} {
			if !contains(ep.Dependencies, node) {
				t.Errorf("%s: %v does not include %s — a cycle result was memoized incomplete",
					key, ep.Dependencies, node)
			}
		}
	}
}

// TestFixturePreferredImpl asserts interface dispatch resolved to the Postgres
// store, not the in-memory one: the SQL evidence exists only on that side, and
// the citations must point at it.
func TestFixturePreferredImpl(t *testing.T) {
	g, _ := buildFixture(t)
	var seen bool
	for _, ep := range g.Routes {
		for _, a := range ep.Evidence {
			if strings.HasPrefix(a.Via, "store.Memory.") {
				t.Errorf("%s %s: evidence attributed to the non-preferred impl (%s at %s)",
					ep.Method, ep.Path, a.Via, a.Site)
			}
			if a.Node == "pg.models" && strings.HasPrefix(a.Via, "store.Postgres.") {
				seen = true
			}
		}
	}
	if !seen {
		t.Error("no pg.models evidence attributed to store.Postgres — dispatch did not reach the SQL")
	}
}

// TestFixtureEdges checks the aggregation the artifact actually publishes: one
// association per namespace/node pair, with the merged mode.
func TestFixtureEdges(t *testing.T) {
	g, _ := buildFixture(t)
	modes := map[string]string{}
	for _, e := range g.StateAccess {
		modes[e.Namespace+" -> "+e.Dependency] = e.Mode
	}
	want := map[string]string{
		"Public -> pg.models":  ir.ModeRead,
		"Public -> pg.usage":   ir.ModeWrite,
		"Public -> mem.cache":  ir.ModeBoth,
		"Public -> mem.flight": ir.ModeBoth,
		"Public -> ext.icons":  ir.ModeBoth,
		"Public -> ext.opaque": ir.ModeRead,
		"Admin -> pg.usage":    ir.ModeRead,
		"Admin -> mem.admins":  ir.ModeRead,
		"Legacy -> mem.cache":  ir.ModeRead,
	}
	for key, mode := range want {
		if modes[key] != mode {
			t.Errorf("edge %s mode = %q, want %q", key, modes[key], mode)
		}
	}
	if g.StateCoverage.Ambiguous != 0 {
		t.Errorf("coverage reports %d ambiguous associations, want 0", g.StateCoverage.Ambiguous)
	}
	if g.StateCoverage.TotalAssociations != len(g.StateAccess) {
		t.Errorf("coverage total = %d, edges = %d", g.StateCoverage.TotalAssociations, len(g.StateAccess))
	}
}

// TestFixtureWriteThroughSkippedField is the regression for a write that reaches
// its node through a chain link the overlay does not name. flight.Cache is known
// by type, its fields are absorbed by the package default, and its fill is
// `c.entries[key] = value` — so the only place the node can be attributed is the
// receiver, one link up from the expression being written. A walk that visited
// the base of a write target as a read published this cache read-only: a reader
// would see a cache nothing ever fills, and the same understatement applied to
// every `deps.types` surface whose method name carries no verb.
func TestFixtureWriteThroughSkippedField(t *testing.T) {
	g, _ := buildFixture(t)
	ep, ok := endpoints(g)["GET /v1/aliases"]
	if !ok {
		t.Fatal("GET /v1/aliases not extracted")
	}
	var modes []string
	for _, a := range ep.Evidence {
		if a.Node != "mem.flight" {
			continue
		}
		modes = append(modes, a.Mode)
		if a.Mode == ir.ModeWrite && strings.Contains(a.Site, "flight/flight.go") {
			return // the fill is evidenced as a write, at the statement that writes
		}
	}
	t.Errorf("no write to mem.flight was evidenced inside flight.Cache.Do; modes seen = %v", modes)
}

// TestFixtureSchemaDefinitions pins the derived table definitions. The claim worth
// protecting is that a table's shape is the CREATE *plus* its migrations: `family`
// exists only in an `ALTER TABLE ... ADD COLUMN`, so a definition read from the
// CREATE alone would publish a schema no live database has.
func TestFixtureSchemaDefinitions(t *testing.T) {
	g, _ := buildFixture(t)
	models := g.Tables["models"]
	if models == nil {
		t.Fatalf("no definition derived for models; tables = %v", sortedTableNames(g))
	}
	if models.Node != "pg.models" {
		t.Errorf("models.node = %q, want pg.models", models.Node)
	}
	type col struct {
		typ, extra string
		migration  bool
	}
	want := map[string]col{
		"id":     {"text", "PRIMARY KEY", false},
		"name":   {"text", "NOT NULL", false},
		"price":  {"numeric(10, 2)", "NOT NULL DEFAULT 0", false},
		"family": {"text", "NOT NULL DEFAULT ''", true},
	}
	if len(models.Columns) != len(want) {
		t.Errorf("models has %d columns, want %d: %+v", len(models.Columns), len(want), models.Columns)
	}
	for _, got := range models.Columns {
		exp, ok := want[got.Name]
		if !ok {
			t.Errorf("unexpected column %+v", got)
			continue
		}
		delete(want, got.Name)
		if got.Type != exp.typ || got.Extra != exp.extra || got.Migration != exp.migration {
			t.Errorf("column %s = {%q %q migration=%v}, want {%q %q migration=%v}",
				got.Name, got.Type, got.Extra, got.Migration, exp.typ, exp.extra, exp.migration)
		}
		// Every column cites the line that declares it, and the citation is a
		// link a reader can follow.
		if !strings.HasPrefix(got.Site, "store/store.go:") {
			t.Errorf("column %s site = %q, want a store/store.go line", got.Name, got.Site)
		}
		if !strings.Contains(got.URL, fixtureRevision) || !strings.HasSuffix(got.URL, "#L"+lineOf(got.Site)) {
			t.Errorf("column %s url = %q, does not link its own line at the pinned revision", got.Name, got.URL)
		}
	}
	for name := range want {
		t.Errorf("column %s was not derived", name)
	}
	// The migration column is cited past the CREATE that lacks it, which is the
	// evidence that the line offset inside the raw literal is counted.
	if a, b := lineOf(models.Columns[0].Site), lineOf(byName(t, models, "family").Site); a >= b {
		t.Errorf("family cited at line %s, not after the CREATE at line %s", b, a)
	}

	usage := g.Tables["usage"]
	if usage == nil {
		t.Fatalf("no definition derived for usage; tables = %v", sortedTableNames(g))
	}
	// Both spellings of a table-level constraint: with and without a space before
	// the paren. `CHECK(...)` unspaced used to parse as a column literally named
	// "check(tokens >= 0)".
	var cons []string
	for _, c := range usage.Constraints {
		cons = append(cons, c.Text)
	}
	if !reflect.DeepEqual(cons, []string{"UNIQUE (id, created_at)", "CHECK(tokens >= 0)"}) {
		t.Errorf("usage constraints = %v, want both table-level constraints", cons)
	}
	if names := columnNames(usage); !reflect.DeepEqual(names, []string{"id", "tokens", "created_at"}) {
		t.Errorf("usage columns = %v; a table-level constraint must not be read as a column", names)
	}
	var kinds []string
	for _, stmt := range usage.DDL {
		kinds = append(kinds, stmt.Kind)
	}
	if !reflect.DeepEqual(kinds, []string{"create", "index"}) {
		t.Errorf("usage ddl kinds = %v, want [create index]", kinds)
	}
}

// TestFixtureUndefinedTable covers the gate behind the definitions: a `pg.*` node
// with no CREATE TABLE means the map draws a table the service never creates, and
// clicking it would show an empty schema.
func TestFixtureUndefinedTable(t *testing.T) {
	_, rep := buildFixture(t, func(cfg *config.Config) {
		cfg.Labels["pg.ghost"] = "ghost"
	})
	if len(rep.UndefinedTable) != 1 || !strings.Contains(rep.UndefinedTable[0], "pg.ghost") {
		t.Errorf("undefined tables = %v, want pg.ghost reported", rep.UndefinedTable)
	}
	if rep.Clean() {
		t.Error("report is clean despite a pg node with no table definition")
	}
	if !strings.Contains(rep.Markdown(), "no table definition") {
		t.Error("report does not carry the undefined-table section")
	}
}

func byName(t *testing.T, table *ir.Table, name string) ir.Column {
	t.Helper()
	for _, col := range table.Columns {
		if col.Name == name {
			return col
		}
	}
	t.Fatalf("table %s has no column %s", table.Name, name)
	return ir.Column{}
}

func columnNames(table *ir.Table) []string {
	out := []string{}
	for _, col := range table.Columns {
		out = append(out, col.Name)
	}
	return out
}

func lineOf(site string) string {
	if i := strings.LastIndex(site, ":"); i >= 0 {
		return site[i+1:]
	}
	return ""
}

func sortedTableNames(g *ir.Graph) []string {
	out := []string{}
	for name := range g.Tables {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// TestFixtureArtifacts renders the two published files and checks they are
// self-consistent: the JSON parses back, and the HTML carries the same graph.
func TestFixtureArtifacts(t *testing.T) {
	g, _ := buildFixture(t)
	inventory, err := g.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	var round ir.Graph
	if err := json.Unmarshal(inventory, &round); err != nil {
		t.Fatalf("inventory.json does not parse: %v", err)
	}
	if round.Revision != fixtureRevision {
		t.Errorf("revision = %q, want %q", round.Revision, fixtureRevision)
	}
	if len(round.Routes) != len(g.Routes) || len(round.Nodes) != len(g.Nodes) {
		t.Errorf("round trip lost data: %d/%d routes, %d/%d nodes",
			len(round.Routes), len(g.Routes), len(round.Nodes), len(g.Nodes))
	}
	if !round.Generator.OverlayComplete {
		t.Error("overlayComplete is false for a complete fixture overlay")
	}
	page, err := render.HTML(g, inventory)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Fixture service", "GET /v1/admin/stats", "pg.usage"} {
		if !strings.Contains(string(page), want) {
			t.Errorf("rendered page does not mention %q", want)
		}
	}
	// The page must be self-contained: no external script or style origins.
	for _, bad := range []string{"src=\"http", "href=\"http://", "cdn.jsdelivr", "unpkg.com"} {
		if strings.Contains(string(page), bad) {
			t.Errorf("rendered page loads a remote asset (%q); it must be self-contained", bad)
		}
	}
}

// TestPageProvenanceViews pins the page's provenance control. The map's whole
// claim is that a reader can tell which facts a compiler stands behind, and the
// README saying so is not the same as the page showing it — so all three views are
// asserted here: `all`, the subtractive `code` view that withholds every string no
// gate can contradict, and `overlay`, which marks each curated layer in place
// against the convention that *unmarked means derived*.
//
// It also pins that the control is a view, not a filter: Reset clears the filters
// and the focus and leaves the view alone, because turning off a filter and losing
// the answer to "who wrote this" would be a surprise.
func TestPageProvenanceViews(t *testing.T) {
	html := renderFixturePage(t)
	for _, want := range []string{
		`data-view="all"`, // the three-way control
		`data-view="code"`,
		`data-view="overlay"`,
		`class="bar" id="codebar"`, // what each view explains about itself
		`class="bar" id="provbar"`,
		`id="withheld"`,             // the code view accounts for what it removed
		"unmarked = <b>derived</b>", // the convention that makes silence meaningful
		"<b>curated structure</b>",  // a person decided it and it moves an edge
		"<b>prose</b>",              // enrichment: presence-checked only
		"<b>unchecked prose</b>",    // roles/credentials: no gate at all
		"body.v-overlay .p-c",       // the three marks, shown only under `overlay`
		"body.v-overlay .p-p",
		"body.v-overlay .p-x",
		"svg.prov .hull-label",       // the curated indirection inside the graph itself
		"body.v-code .prose-section", // sections that are only prose go whole
		`class="prose-section"`,      // …and something actually carries that class
		"classList.add('v-' + next)", // the view is a body class, so CSS can subtract
		"var(--barh)",                // the banner gives its height back to the graph
	} {
		if !strings.Contains(html, want) {
			t.Errorf("page is missing the provenance control's %q", want)
		}
	}
	// The subtraction has to run through one predicate, or "code only" becomes a
	// list of places someone remembered. say() withholds a sentence, label() falls
	// back to the node id, and both answer to showProse().
	for _, want := range []string{
		"const showProse = () => state.view !== 'code'",
		"const say = s => (showProse() ? (s || '') : '')",
		"showProse() ? (DATA.labels && DATA.labels[id]) || id : id",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("code view is missing its withholding primitive %q", want)
		}
	}
	// Every layer a person is responsible for is actually marked somewhere: the
	// scaffolding existing without call sites would render a lens that marks nothing.
	for _, fn := range []string{"pc(el(", "pp(el(", "px(el("} {
		if !strings.Contains(html, fn) {
			t.Errorf("no render site calls %s — a mark with no use marks nothing", fn)
		}
	}
	reset := slice(t, html, "getElementById('reset').onclick", "};")
	for _, leak := range []string{"view", "prov"} {
		if strings.Contains(reset, leak) {
			t.Errorf("Reset touches %q; the provenance view is a view over the page, not a filter on it", leak)
		}
	}
	if !strings.Contains(reset, "focus: null") {
		t.Error("Reset leaves the focused node shadowing the rest of the system")
	}
}

// TestPageTopologyFingerprint pins the mechanism that makes "the overlay is
// additive" checkable instead of asserted. The caption publishes a hash of the
// drawn topology, and it is read back off the DOM — a value computed once from the
// data could not move by construction, so it would prove nothing about what the
// page actually rendered under a different view.
func TestPageTopologyFingerprint(t *testing.T) {
	html := renderFixturePage(t)
	for _, want := range []string{
		`id="topo"`,
		"const nodeTopo = n => n.id + '@' + n.group + '@' + n.cluster;",
		"const linkTopo = l => l.s.id + '>' + l.t.id + ':' + l.mode;",
		"'data-topo': nodeTopo(n)",
		"'data-topo': linkTopo(l)",
		"gsvg.querySelectorAll(sel)", // read back from what was drawn, not from DATA
		"topoFingerprint()",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("page is missing the topology fingerprint's %q", want)
		}
	}
	// The fingerprint has to be recomputed on every redraw, including the redraw a
	// view change triggers, or it stops being evidence.
	draw := slice(t, html, "function draw() {", "}")
	if !strings.Contains(draw, "topoFingerprint()") {
		t.Error("draw() does not refresh the fingerprint, so a view change could move the graph unnoticed")
	}
	if setView := slice(t, html, "function setView(next) {", "\n}"); !strings.Contains(setView, "draw();") {
		t.Error("setView does not redraw, so the fingerprint would not be re-read per view")
	}
}

// TestPageExplorerAffordances pins the parts of the page that answer "what does
// this thing touch, and what is it" rather than "what exists": labels that keep one
// size at every zoom and are dropped when they would collide, a click that shadows
// everything off the clicked node's edges, a table drawer that can hold a 79-column
// definition, the identity filter, and the prose fields the pinned panel exists to
// show.
func TestPageExplorerAffordances(t *testing.T) {
	html := renderFixturePage(t)

	// Labels must live outside the scaled scene. Text that scales with the zoom
	// collides identically at every zoom, which is what buried the picture.
	scene := strings.Index(html, `<g id="scene">`)
	labels := strings.Index(html, `<g id="glabels">`)
	if scene < 0 || labels < 0 {
		t.Fatal("page has no #scene or no #glabels layer")
	}
	if labels < scene {
		t.Fatal("#glabels is declared before #scene")
	}
	if between := html[scene:labels]; strings.Count(between, "<g ") != strings.Count(between, "</g>") {
		t.Errorf("#glabels sits inside #scene (%d open <g> vs %d close between them); "+
			"labels would scale with the zoom", strings.Count(between, "<g "), strings.Count(between, "</g>"))
	}

	for _, want := range []string{
		"const LABEL_BUDGET",   // a bounded number of names on screen at once
		"function placeLabels", // …placed per frame in screen space
		"const sx = x =>", "const sy = y =>",
		".glabel.pri",    // the focused neighbourhood outranks degree
		".gnode.shade {", // click-to-shadow, the interaction that was missing
		".glink.shade {", // including the edges, or the shadow reads as a hairball
		"function focusNode", "function clearFocus",
		"body.focused .gfocus", `id="gfocusclear"`,
		"'Escape'",      // Esc clears it
		".gschema.wide", // the drawer widens instead of only scrolling
		".ginfo.pinned", // a click pins a panel wide enough for the prose
		`id="ont"`,      // the ontological axis
		`value="source"`, `value="literal"`, `value="symbol"`, `value="unreached"`,
		"const ontOK = dep =>",
		"function identTier",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("page is missing the explorer affordance %q", want)
		}
	}

	// The graph names nodes by their short name; the long curated label is what
	// made the picture unreadable, and it belongs in the panel.
	if !strings.Contains(html, "const shortName = id =>") {
		t.Error("graph labels are not shortened, so long curated labels are back on the canvas")
	}

	// Regression: the `unreached` identity asks for nodes no endpoint reaches, so
	// deriving their visibility from matching endpoints hid the only nodes the filter
	// exists to show. Both the graph and the boundary chips must select them directly.
	if !strings.Contains(html, "const ontPicks = id =>") {
		t.Fatal("no ontPicks predicate: the `unreached` identity has nothing to select nodes by")
	}
	for _, site := range []string{
		slice(t, html, "function styleGraph() {", "const selected ="),
		slice(t, html, "function drawBoundaries() {", "\n}"),
	} {
		if !strings.Contains(site, "ontPicks(") {
			t.Error("a visibility site ignores ontPicks, so filtering to `unreached` hides " +
				"the declared-but-unreached nodes it asked for")
		}
	}

	// The pinned panel must render every prose field the overlay carries for a
	// node. Rendering one of eight is what made clicking an in-memory node useless.
	docs := slice(t, html, "const DOC_FIELDS = [", "];")
	for _, field := range []string{"represents", "construction", "access", "concurrency", "lifecycle", "restart"} {
		if !strings.Contains(docs, "'"+field+"'") {
			t.Errorf("the pinned panel does not render depDocs.%s", field)
		}
	}
}

// TestOverlayLegendFieldsMatchSchema guards a failure mode that renders silently:
// the actors and credentials legends read their fields by name, so a field the
// overlay does not use produces an empty card rather than an error. Every key the
// page reads has to exist on the loaded overlay.
func TestOverlayLegendFieldsMatchSchema(t *testing.T) {
	g, _ := buildFixture(t)
	// Scoped to the legend's own body: `r.namespace` elsewhere on the page contains
	// `r.name`, so a whole-document search cannot answer this question.
	legend := slice(t, renderFixturePage(t), "function drawLegend() {", "\n}")
	if len(g.Roles) == 0 || len(g.Credentials) == 0 {
		t.Fatal("fixture overlay declares no roles or credentials to check the legend against")
	}
	for _, want := range []string{"r.title", "r.kind", "r.summary", "r.callers", "r.credentials", "r.custody"} {
		if !strings.Contains(legend, want) {
			t.Errorf("the actors legend does not read %s", want)
		}
	}
	for _, want := range []string{"c.title", "c.class", "c.issuer", "c.holder", "c.lifetime",
		"c.clientStorage", "c.serverStorage", "c.validation", "c.usedBy", "c.sources"} {
		if !strings.Contains(legend, want) {
			t.Errorf("the credentials legend does not read %s", want)
		}
	}
	// The inverse: a name the overlay does not carry renders an empty card instead
	// of an error, which is the failure this test exists to catch.
	for _, dead := range []string{"r.name", "r.description", "c.name", "c.description"} {
		if strings.Contains(legend, dead) {
			t.Errorf("the legend still reads %s, which the overlay schema does not carry", dead)
		}
	}
}

// TestNodeIdentityOrigin pins the ontological axis the page filters on. Whether
// source *reaches* a node is derived; how much of the node's *name* a person
// invented is a separate question, and this is the answer to it. A `pg.*` node is
// named by the CREATE TABLE source issues, a host is a curated name bound to a
// literal the compiler found, and a field, type or function node is a curated name
// bound to a symbol.
func TestNodeIdentityOrigin(t *testing.T) {
	g, _ := buildFixture(t)
	want := map[string][]string{
		"pg.models":    {"sql"}, // source names it
		"pg.usage":     {"sql"},
		"ext.icons":    {"hosts"},     // curated name on a literal
		"ext.opaque":   {"functions"}, // curated name on a symbol
		"mem.cache":    {"fields"},
		"mem.aliases":  {"fields"},
		"mem.admins":   {"fields"},
		"mem.inflight": {"fields"},
		// Reached two ways — through the field that holds it and through the type
		// that is it — so both tables named it.
		"mem.flight": {"fields", "types"},
	}
	for id, origins := range want {
		node, ok := g.Nodes[id]
		if !ok {
			t.Errorf("fixture has no node %q", id)
			continue
		}
		if !reflect.DeepEqual(node.NamedBy, origins) {
			t.Errorf("%s namedBy = %v, want %v", id, node.NamedBy, origins)
		}
	}
	// Sentinels are decisions not to draw a node, so they must name nothing.
	for _, sentinel := range []string{"@skip", "@sql", "@through"} {
		if node, ok := g.Nodes[sentinel]; ok {
			t.Errorf("sentinel %q became a node (namedBy %v)", sentinel, node.NamedBy)
		}
	}
	// Every drawn node has an origin: one with none would filter into no bucket at
	// all and quietly vanish from the ontological view.
	for id, node := range g.Nodes {
		if len(node.NamedBy) == 0 {
			t.Errorf("node %q has no identity origin, so no ontology filter can reach it", id)
		}
	}
}

// renderFixturePage renders the published page over the fixture service. The
// stylesheet and the behaviour are separate files that the generator injects, so
// the assertions have to run against the rendered output, not against page.html.
func renderFixturePage(t *testing.T) string {
	t.Helper()
	g, _ := buildFixture(t)
	inventory, err := g.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	page, err := render.HTML(g, inventory)
	if err != nil {
		t.Fatal(err)
	}
	return string(page)
}

// slice returns the text from `open` up to the next `close`, failing the test when
// either marker is gone — so a renamed function shows up as a missing marker rather
// than as an assertion that silently passes over an empty string.
func slice(t *testing.T, html, open, close string) string {
	t.Helper()
	i := strings.Index(html, open)
	if i < 0 {
		t.Fatalf("page has no %q", open)
	}
	rest := html[i+len(open):]
	j := strings.Index(rest, close)
	if j < 0 {
		t.Fatalf("no %q closes %q", close, open)
	}
	return rest[:j]
}

// TestCheckWritesNothing covers the contract the ignored artifact depends on:
// -check renders the whole map — so a broken template or an unmarshalable graph
// still fails the gate — but leaves no file behind for someone to commit.
func TestCheckWritesNothing(t *testing.T) {
	root, err := filepath.Abs("testdata/fixture")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	// -out is resolved against -root, so the throwaway directory has to be
	// expressed as the hop from the fixture to it.
	out, err := filepath.Rel(root, dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := run(root, "svcfix.test", "overlay.json", out, fixtureRevision, true, true); err != nil {
		t.Fatalf("check failed on the complete fixture: %v", err)
	}
	left, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		names := []string{}
		for _, e := range left {
			names = append(names, e.Name())
		}
		t.Errorf("-check wrote %v; it must only report", names)
	}

	// The same run without -check is what CI and Pages publish.
	if err := run(root, "svcfix.test", "overlay.json", out, fixtureRevision, false, true); err != nil {
		t.Fatalf("generate failed on the complete fixture: %v", err)
	}
	for _, name := range []string{"inventory.json", "system-map.html", "report.md"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("generate did not write %s: %v", name, err)
		}
	}
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}
