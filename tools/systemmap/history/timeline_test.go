package history

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

// The encoding is the one thing in this package that has no compiler and no gate
// behind it: the extractor is the map's own, and the layout detection either finds a
// go.mod or says so, but the deltas are a hand-written difference that the page then
// replays in both directions. A bug there is a slider that shows a shape the service
// never had, silently — which is why these tests replay the artifact rather than
// inspecting it.

// shape is a terse fixture: routes as keys, nodes as ids, wires as "route|node|mode".
func shape(rev string, routes, nodes, wires []string) *Shape {
	sh := &Shape{Rev: rev, Date: "2026-01-0" + rev, Subject: "commit " + rev}
	for _, r := range routes {
		sh.Routes = append(sh.Routes, RouteMeta{Key: r, Namespace: "ns", Group: "ns:ns", Auth: "public"})
	}
	for _, n := range nodes {
		sh.Nodes = append(sh.Nodes, NodeMeta{ID: n, Category: "pg", Group: "cat:pg", Label: n})
	}
	for _, w := range wires {
		parts := strings.SplitN(w, "|", 3)
		if len(parts) != 3 {
			panic("wire fixture must be route|node|mode: " + w)
		}
		sh.Links = append(sh.Links, Link{Route: parts[0], Node: parts[1], Mode: parts[2]})
	}
	return sh
}

// live is the page's replay, in Go: one mutable set stepped forward by a point's
// removals and then its additions. It is deliberately written the same way round as
// `fwd` in page.timeline.js — removals first — because that ordering is what makes a wire whose
// access mode changed (encoded as one removed and one added, same endpoints) survive.
type live struct {
	routes map[string]bool
	nodes  map[string]bool
	wires  map[string]string
}

func replay(tl *Timeline, upto int) live {
	st := live{routes: map[string]bool{}, nodes: map[string]bool{}, wires: map[string]string{}}
	for i := 0; i <= upto; i++ {
		st.forward(tl, tl.Snapshots[i])
	}
	return st
}

func (st live) forward(tl *Timeline, p Point) {
	for _, x := range p.RoutesDel {
		delete(st.routes, tl.Routes[x].Key)
	}
	for _, x := range p.NodesDel {
		delete(st.nodes, tl.Nodes[x].ID)
	}
	for _, x := range p.LinksDel {
		delete(st.wires, tl.wkey(x))
	}
	for _, x := range p.RoutesAdd {
		st.routes[tl.Routes[x].Key] = true
	}
	for _, x := range p.NodesAdd {
		st.nodes[tl.Nodes[x].ID] = true
	}
	for _, x := range p.LinksAdd {
		st.wires[tl.wkey(x)] = tl.Links[x].Mode
	}
}

func (st live) backward(tl *Timeline, p Point) {
	for _, x := range p.RoutesAdd {
		delete(st.routes, tl.Routes[x].Key)
	}
	for _, x := range p.NodesAdd {
		delete(st.nodes, tl.Nodes[x].ID)
	}
	for _, x := range p.LinksAdd {
		delete(st.wires, tl.wkey(x))
	}
	for _, x := range p.RoutesDel {
		st.routes[tl.Routes[x].Key] = true
	}
	for _, x := range p.NodesDel {
		st.nodes[tl.Nodes[x].ID] = true
	}
	for _, x := range p.LinksDel {
		st.wires[tl.wkey(x)] = tl.Links[x].Mode
	}
}

func (t *Timeline) wkey(i int) string {
	l := t.Links[i]
	return t.Routes[l.R].Key + "\x00" + t.Nodes[l.N].ID
}

// want is a shape as the replay would hold it, for comparison.
func want(sh *Shape) live {
	st := live{routes: map[string]bool{}, nodes: map[string]bool{}, wires: map[string]string{}}
	for _, r := range sh.Routes {
		st.routes[r.Key] = true
	}
	for _, n := range sh.Nodes {
		st.nodes[n.ID] = true
	}
	for _, l := range sh.Links {
		st.wires[l.Route+"\x00"+l.Node] = l.Mode
	}
	return st
}

func encodeAll(shapes []*Shape) *Timeline {
	tl := &Timeline{Ref: "test"}
	routeIdx, nodeIdx, linkIdx := map[string]int{}, map[string]int{}, map[string]int{}
	var prev *Shape
	for _, sh := range shapes {
		tl.Snapshots = append(tl.Snapshots, encode(tl, sh, prev, routeIdx, nodeIdx, linkIdx))
		prev = sh
	}
	return tl
}

// The fixture covers every kind of change a commit can make to the shape: a route
// added, a route removed, a node added, a node removed and brought back, a wire
// added, a wire removed, and — the one the encoding is easiest to get wrong on — a
// wire whose access mode changed between two things that both stayed.
func fixture() []*Shape {
	return []*Shape{
		shape("1",
			[]string{"GET /a", "GET /b"},
			[]string{"pg.x", "pg.y"},
			[]string{"GET /a|pg.x|R", "GET /b|pg.y|W"}),
		shape("2", // a route and a node arrive; /a starts writing what it only read
			[]string{"GET /a", "GET /b", "POST /c"},
			[]string{"pg.x", "pg.y", "mem.cache"},
			[]string{"GET /a|pg.x|RW", "GET /b|pg.y|W", "POST /c|mem.cache|W"}),
		shape("3", // /b and the node it was the only reader of go away
			[]string{"GET /a", "POST /c"},
			[]string{"pg.x", "mem.cache"},
			[]string{"GET /a|pg.x|RW", "POST /c|mem.cache|W"}),
		shape("4", // nothing changes at all: a commit that touched the service
			[]string{"GET /a", "POST /c"},
			[]string{"pg.x", "mem.cache"},
			[]string{"GET /a|pg.x|RW", "POST /c|mem.cache|W"}),
		shape("5", // the deleted node comes back, and /a goes back to reading
			[]string{"GET /a", "POST /c"},
			[]string{"pg.x", "pg.y", "mem.cache"},
			[]string{"GET /a|pg.x|R", "GET /a|pg.y|R", "POST /c|mem.cache|W"}),
	}
}

func TestEncodeReplaysForward(t *testing.T) {
	shapes := fixture()
	tl := encodeAll(shapes)
	if len(tl.Snapshots) != len(shapes) {
		t.Fatalf("encoded %d points from %d shapes", len(tl.Snapshots), len(shapes))
	}
	for i, sh := range shapes {
		got, expect := replay(tl, i), want(sh)
		if !reflect.DeepEqual(got, expect) {
			t.Errorf("point %d (%s) replays to a different shape:\n got %+v\nwant %+v", i, sh.Rev, got, expect)
		}
		p := tl.Snapshots[i]
		if p.Counts.Routes != len(sh.Routes) || p.Counts.Nodes != len(sh.Nodes) || p.Counts.Links != len(sh.Links) {
			t.Errorf("point %d counts %+v disagree with the shape (%d/%d/%d)",
				i, p.Counts, len(sh.Routes), len(sh.Nodes), len(sh.Links))
		}
	}
}

// The slider is dragged backwards as often as forwards, so undoing a point has to
// restore exactly the shape before it — which is the whole reason deletions carry an
// index into the union table rather than being implied.
func TestEncodeReplaysBackward(t *testing.T) {
	shapes := fixture()
	tl := encodeAll(shapes)
	st := replay(tl, len(shapes)-1)
	for i := len(shapes) - 1; i > 0; i-- {
		st.backward(tl, tl.Snapshots[i])
		if expect := want(shapes[i-1]); !reflect.DeepEqual(st, expect) {
			t.Fatalf("stepping back off point %d does not restore point %d:\n got %+v\nwant %+v",
				i, i-1, st, expect)
		}
	}
}

// A commit that touched the service without changing its shape must encode to no
// deltas at all. Otherwise the page would report a diff for it, and a reader stepping
// through four hundred commits would be told that most of them changed something.
func TestUnchangedPointIsEmpty(t *testing.T) {
	tl := encodeAll(fixture())
	p := tl.Snapshots[3]
	if n := len(p.RoutesAdd) + len(p.RoutesDel) + len(p.NodesAdd) + len(p.NodesDel) +
		len(p.LinksAdd) + len(p.LinksDel); n != 0 {
		t.Fatalf("a point identical to its predecessor encoded %d changes: %+v", n, p)
	}
	// omitempty is what keeps that cheap on the wire, and the page reads a missing
	// list as an empty one.
	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{`"ra"`, `"rd"`, `"na"`, `"nd"`, `"la"`, `"ld"`} {
		if strings.Contains(string(raw), key) {
			t.Errorf("an unchanged point still carries %s: %s", key, raw)
		}
	}
}

// A mode change is the case the union table's identity has to get right: the same two
// endpoints, twice, so the page recolours the wire instead of silently keeping the old
// colour. The delta must be one removal and one addition, and the two entries must be
// different rows of the union table.
func TestModeChangeIsOneRemovalAndOneAddition(t *testing.T) {
	tl := encodeAll(fixture())
	p := tl.Snapshots[1] // GET /a → pg.x goes from R to RW
	var added, removed []LinkRef
	for _, x := range p.LinksAdd {
		added = append(added, tl.Links[x])
	}
	for _, x := range p.LinksDel {
		removed = append(removed, tl.Links[x])
	}
	find := func(list []LinkRef, mode string) bool {
		for _, l := range list {
			if tl.Routes[l.R].Key == "GET /a" && tl.Nodes[l.N].ID == "pg.x" && l.Mode == mode {
				return true
			}
		}
		return false
	}
	if !find(removed, "R") {
		t.Errorf("the R wire was not removed: %+v", removed)
	}
	if !find(added, "RW") {
		t.Errorf("the RW wire was not added: %+v", added)
	}
	// And the replay ends up with the new colour rather than either the old one or
	// nothing at all, which are the two ways a naive ordering breaks it.
	if got := replay(tl, 1).wires["GET /a\x00pg.x"]; got != "RW" {
		t.Errorf("after the mode change the wire replays as %q, want RW", got)
	}
}

// The union tables are append-only and interned, so a thing that comes back after
// being deleted must reuse its original row rather than being added twice. Otherwise
// the file grows with the churn instead of with the system.
func TestUnionTablesAreInterned(t *testing.T) {
	tl := encodeAll(fixture())
	seen := map[string]bool{}
	for _, n := range tl.Nodes {
		if seen[n.ID] {
			t.Errorf("node %s appears twice in the union table", n.ID)
		}
		seen[n.ID] = true
	}
	// pg.y is deleted at point 3 and returns at point 5.
	if !seen["pg.y"] || len(tl.Nodes) != 3 {
		t.Errorf("union node table is %+v, want exactly pg.x, pg.y, mem.cache", tl.Nodes)
	}
	if got := replay(tl, 4).nodes["pg.y"]; !got {
		t.Error("a node deleted and reintroduced does not come back on replay")
	}
}

// Every index in a point has to resolve. A link's endpoints are interned when the link
// is, which only works because links are encoded after routes and nodes — get that
// order wrong and the page reads `undefined.key`.
func TestEveryIndexResolves(t *testing.T) {
	tl := encodeAll(fixture())
	for i, p := range tl.Snapshots {
		check := func(what string, list []int, n int) {
			for _, x := range list {
				if x < 0 || x >= n {
					t.Fatalf("point %d: %s index %d is outside a table of %d", i, what, x, n)
				}
			}
		}
		check("route", append(p.RoutesAdd, p.RoutesDel...), len(tl.Routes))
		check("node", append(p.NodesAdd, p.NodesDel...), len(tl.Nodes))
		check("link", append(p.LinksAdd, p.LinksDel...), len(tl.Links))
	}
	for i, l := range tl.Links {
		if l.R < 0 || l.R >= len(tl.Routes) || l.N < 0 || l.N >= len(tl.Nodes) {
			t.Fatalf("link %d (%+v) points outside the route or node table", i, l)
		}
	}
}

// Marshal is what the page parses, so the artifact has to survive the round trip with
// the deltas intact — including the empty point, whose lists are absent on the wire.
func TestMarshalRoundTrip(t *testing.T) {
	tl := encodeAll(fixture())
	raw, err := tl.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	var back Timeline
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatalf("the artifact does not parse: %v", err)
	}
	for i := range tl.Snapshots {
		if !reflect.DeepEqual(replay(tl, i), replay(&back, i)) {
			t.Fatalf("point %d replays differently after a round trip", i)
		}
	}
}

// A snapshot's wires have to be coloured the way the page's `epMode` colours them, or
// the last point recolours the map the moment the slider is touched. The rule is: the
// endpoint's own derived mode, and the namespace's aggregate only where the endpoint
// has none. This is the regression test for having had it the other way round, which
// repainted 98 of 976 wires at the head revision.
func TestWiresPreferTheEndpointsOwnMode(t *testing.T) {
	routes := []*ir.Endpoint{
		{Method: "GET", Path: "/a", DepModes: map[string]string{"pg.x": "R"}},
		{Method: "POST", Path: "/b", DepModes: map[string]string{"pg.x": "RW"}},
		// An endpoint the extractor derived no mode for, which is what the aggregate is
		// the fallback for.
		{Method: "GET", Path: "/c", DepModes: map[string]string{}},
		// And one whose entry exists but is empty, which must fall back too rather than
		// drawing a wire with no colour.
		{Method: "GET", Path: "/d", DepModes: map[string]string{"pg.x": ""}},
	}
	access := []*ir.Edge{{
		Namespace: "ns", Dependency: "pg.x", Mode: "RW",
		Routes: []string{"GET /a", "POST /b", "GET /c", "GET /d"},
	}}
	got := map[string]string{}
	for _, l := range wires(routes, access) {
		got[l.Route] = l.Mode
	}
	expect := map[string]string{"GET /a": "R", "POST /b": "RW", "GET /c": "RW", "GET /d": "RW"}
	if !reflect.DeepEqual(got, expect) {
		t.Errorf("wire modes = %v, want %v", got, expect)
	}
}

// One wire per route in the edge's list, because that is one line each in the picture:
// a snapshot's link count is the number of lines it had, not the number of aggregated
// edges the IR stored.
func TestWiresAreOnePerRouteNotPerEdge(t *testing.T) {
	access := []*ir.Edge{
		{Dependency: "pg.x", Mode: "R", Routes: []string{"GET /a", "GET /b", "GET /c"}},
		{Dependency: "mem.q", Mode: "W", Routes: []string{"GET /a"}},
	}
	if got := wires(nil, access); len(got) != 4 {
		t.Errorf("two edges over four routes produced %d wires: %+v", len(got), got)
	}
}

// Detect reads the layout out of the checkout rather than a table of commits, which is
// the claim that a snapshot from any of this repository's three module eras resolves.
// The three trees are built here rather than checked out, so the test states the shapes
// it covers instead of depending on which commits happen to be fetched.
func TestDetectFindsEachModuleEra(t *testing.T) {
	cases := []struct {
		name    string
		modAt   string // where go.mod goes, relative to the root
		pkgAt   string // where the route table package goes
		module  string
		wantDir string
		wantPfx string
	}{
		{"today: one module at the root, packages under coordinator/",
			".", "coordinator/api", "github.com/eigeninference/d-inference", ".", "coordinator/"},
		{"the coordinator's own module, packages under internal/",
			"coordinator", "coordinator/internal/api", "github.com/eigeninference/coordinator", "coordinator", "internal/"},
		{"an early module whose packages sat at its root",
			"coordinator", "coordinator/api", "github.com/dginf/coordinator", "coordinator", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			if err := os.MkdirAll(filepath.Join(root, tc.pkgAt), 0o755); err != nil {
				t.Fatal(err)
			}
			mod := filepath.Join(root, tc.modAt, "go.mod")
			if err := os.MkdirAll(filepath.Dir(mod), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(mod, []byte("module "+tc.module+"\n\ngo 1.25\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			lay, err := Detect(root, "coordinator/api")
			if err != nil {
				t.Fatal(err)
			}
			if lay.Module != tc.module {
				t.Errorf("module = %q, want %q", lay.Module, tc.module)
			}
			if lay.Prefix != tc.wantPfx {
				t.Errorf("prefix = %q, want %q", lay.Prefix, tc.wantPfx)
			}
			if got := filepath.Join(root, tc.wantDir); lay.Dir != filepath.Clean(got) {
				t.Errorf("dir = %q, want %q", lay.Dir, got)
			}
		})
	}
}

func TestDetectRefusesATreeWithNoModule(t *testing.T) {
	if _, err := Detect(t.TempDir(), "coordinator/api"); err == nil {
		t.Fatal("Detect accepted a directory with no go.mod")
	}
}

// A checkout with a module but no route table package is the shape a commit from
// before the service existed has, and the walk has to say so rather than extract an
// empty map that the timeline would then draw as a service with no endpoints.
func TestDetectRefusesATreeWithNoRouteTable(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Detect(root, "coordinator/api"); err == nil {
		t.Fatal("Detect accepted a checkout with no route table package")
	}
}

// Retarget is what lets one curated overlay describe every commit: the packages moved,
// the curated facts did not. The keys of deps.fields are the ones that matter — they
// are how a struct field becomes a node — so they are what this checks, along with the
// analyze pattern, which decides what is type-checked at all.
func TestRetargetRewritesPackagePaths(t *testing.T) {
	overlay := []byte(`{
	  "service": {"routeTable": {"package": "coordinator/api"}},
	  "deps": {
	    "analyze": ["./coordinator/..."],
	    "fields": {"coordinator/api:Server.store": "pg.users",
	               "coordinator/registry:Registry.queue": "mem.queue"}
	  },
	  "prose": {"note": "the coordinator/api package holds the route table"}
	}`)
	out, err := Retarget(overlay, "coordinator/", "internal/")
	if err != nil {
		t.Fatal(err)
	}
	var tree struct {
		Service struct {
			RouteTable struct{ Package string } `json:"routeTable"`
		}
		Deps struct {
			Analyze []string
			Fields  map[string]string
		}
	}
	if err := json.Unmarshal(out, &tree); err != nil {
		t.Fatal(err)
	}
	if tree.Service.RouteTable.Package != "internal/api" {
		t.Errorf("route table package = %q", tree.Service.RouteTable.Package)
	}
	if len(tree.Deps.Analyze) != 1 || tree.Deps.Analyze[0] != "./internal/..." {
		t.Errorf("analyze = %v, want [./internal/...]", tree.Deps.Analyze)
	}
	keys := make([]string, 0, len(tree.Deps.Fields))
	for k := range tree.Deps.Fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	expect := []string{"internal/api:Server.store", "internal/registry:Registry.queue"}
	if !reflect.DeepEqual(keys, expect) {
		t.Errorf("field keys = %v, want %v", keys, expect)
	}
	// The values are node ids and must survive untouched, or every field would map to
	// a node the overlay does not declare.
	if tree.Deps.Fields["internal/api:Server.store"] != "pg.users" {
		t.Errorf("a node id was rewritten: %v", tree.Deps.Fields)
	}
}

// Retargeting to the prefix already in force must not rewrite anything, because that
// is the head revision's own snapshot and it has to reproduce the map exactly.
func TestRetargetIsIdentityAtTheCurrentPrefix(t *testing.T) {
	raw := []byte(`{"a":"coordinator/api"}`)
	out, err := Retarget(raw, "coordinator/", "coordinator/")
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != string(raw) {
		t.Errorf("Retarget rewrote the overlay at its own prefix: %s", out)
	}
}

func TestRetargetRefusesAnEmptyPrefix(t *testing.T) {
	if _, err := Retarget([]byte(`{}`), "", "internal/"); err == nil {
		t.Fatal("Retarget accepted an empty prefix, which would rewrite every character")
	}
}

// The scratch worktree is where several hundred checkouts land, so the two ways of
// pointing it at something a reader cares about have to be refused rather than
// discovered.
func TestPrepareWorktreeRefusesTheRepositoryItself(t *testing.T) {
	repo := t.TempDir()
	if err := prepareWorktree(repo, repo, "HEAD"); err == nil {
		t.Fatal("prepareWorktree accepted the repository as its own scratch checkout")
	}
	if err := prepareWorktree(repo, "", "HEAD"); err == nil {
		t.Fatal("prepareWorktree accepted an empty scratch path")
	}
}

func TestPrefixOf(t *testing.T) {
	for pkg, want := range map[string]string{
		"coordinator/api": "coordinator/",
		"internal/api":    "internal/",
		"api":             "",
		"a/b/c":           "a/",
	} {
		if got := prefixOf(pkg); got != want {
			t.Errorf("prefixOf(%q) = %q, want %q", pkg, got, want)
		}
	}
}
