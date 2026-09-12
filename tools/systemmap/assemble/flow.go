package assemble

// The wiring of an endpoint: which constructions it reaches, in what order, along
// which call paths, and how often.
//
// The route table answers "what state does this endpoint touch". It does not answer
// the question a reader actually arrives with, which is "and in what order, through
// what, and is that touch on the straight line of the request or off in a
// goroutine". Those facts are all in the walk already — it visits statements in
// source order and knows whether it followed a direct call, an interface, a `defer`
// or a `go` — and they were being thrown away when the per-access evidence was
// aggregated into a sorted dependency list.
//
// What the order *is*: the sequence the type-checked call graph is walked in,
// pre-order, from the outermost middleware to the last statement of the handler. It
// is the order a person reading the source meets these constructions. It is not a
// runtime trace and cannot be — nothing here runs the program — so Touches counts
// distinct source sites rather than executions, and Repeats is the only claim made
// about a site running more than once. Two touches inside the same `if`/`else` both
// appear, in source order, because static reachability is what the whole map is.

import (
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

const (
	// How many distinct call paths one step publishes. A construction reached three
	// ways is worth showing three ways; reached thirty ways, the fourth path teaches
	// nothing that the count does not.
	maxWires = 3
	// How many touch citations one step publishes, for the same reason the edges cap
	// theirs: enough to point a reader at the code.
	maxStepSites = 4
)

// intern assigns stable indices to the strings the steps reference. The same
// function label appears on a hundred endpoints' call paths and the same citation on
// every step that shares a site, so interning them is what keeps per-endpoint
// wiring affordable in a single-file artifact.
type intern struct {
	idx map[string]int
	out []string
}

func (t *intern) id(s string) int {
	if i, ok := t.idx[s]; ok {
		return i
	}
	if t.idx == nil {
		t.idx = map[string]int{}
	}
	i := len(t.out)
	t.idx[s] = i
	t.out = append(t.out, s)
	return i
}

func (t *intern) list() []string {
	if t.out == nil {
		return []string{}
	}
	return t.out
}

// buildFlows folds every endpoint's evidence into its wiring steps and fills the
// graph's interning tables.
func buildFlows(g *ir.Graph) {
	symbols, sites := &intern{}, &intern{}
	for _, ep := range g.Routes {
		ep.Flow = flowOf(ep, symbols, sites)
	}
	g.Symbols, g.Sites = symbols.list(), sites.list()
}

// wire is one call path to a construction, and the earliest point in the walk it
// was taken at.
type wire struct {
	path  []string
	order int
}

// step accumulates one construction's touches while the evidence is scanned.
type step struct {
	node     string
	order    int // the earliest touch: what the step is sequenced by
	depth    int // the call depth of that earliest touch
	kind     string
	leadKind string // the indirection of that earliest touch
	iface    bool
	repeats  bool
	wires    map[string]*wire
	sites    map[string]int // citation -> the earliest order it was touched at
}

// flowOf builds one endpoint's ordered wiring.
//
// The step's Kind is the *strongest* indirection over all of its touches, not the
// first touch's: an endpoint that reads a cache directly and also writes it from a
// goroutine can touch it concurrently, and publishing "direct" because the direct
// touch came first would be the stronger claim to make. Depth and the leading wire
// belong to the earliest touch instead, so that they agree with the sequence number
// beside them.
//
// Which means the two can disagree — the arrow says "deferred" because some later
// touch is, while the path printed under it is a plain call — so the earliest touch's
// own kind is published as LeadKind whenever it is the weaker of the two. Without it
// the artifact prints a sentence about unwinding beside a wire that does not unwind.
// Iface is ORed rather than ranked, because dispatch uncertainty is a different
// question from when the touch happens and a `defer` further along must not answer it.
func flowOf(ep *ir.Endpoint, symbols, sites *intern) []ir.Step {
	byNode := map[string]*step{}
	var order []string
	for _, a := range ep.Evidence {
		// The earliest touch's kind is Access.Lead and not Access.Kind: an entry that
		// absorbed a duplicate carries the strongest kind of everything that reached
		// its line, while Lead is the kind of the path it kept. Taking Kind here would
		// silently agree with itself and suppress LeadKind exactly when it is needed.
		cur, ok := byNode[a.Node]
		if !ok {
			cur = &step{node: a.Node, order: a.Order, depth: a.Depth, leadKind: leadOf(a),
				wires: map[string]*wire{}, sites: map[string]int{}}
			byNode[a.Node] = cur
			order = append(order, a.Node)
		}
		if a.Order < cur.order {
			cur.order, cur.depth, cur.leadKind = a.Order, a.Depth, leadOf(a)
		}
		cur.kind = ir.StrongerKind(cur.kind, a.Kind)
		cur.iface = cur.iface || a.Iface
		cur.repeats = cur.repeats || a.Loop
		path := append(append(make([]string, 0, len(a.Path)+1), a.Path...), a.Via)
		sig := strings.Join(path, "\x00")
		if w, ok := cur.wires[sig]; !ok {
			cur.wires[sig] = &wire{path: path, order: a.Order}
		} else if a.Order < w.order {
			w.order = a.Order
		}
		if at, ok := cur.sites[a.Site]; !ok || a.Order < at {
			cur.sites[a.Site] = a.Order
		}
	}

	sort.SliceStable(order, func(i, j int) bool {
		a, b := byNode[order[i]], byNode[order[j]]
		if a.order != b.order {
			return a.order < b.order
		}
		return a.node < b.node
	})

	out := make([]ir.Step, 0, len(order))
	for i, id := range order {
		cur := byNode[id]
		s := ir.Step{
			Seq:       i + 1,
			Node:      id,
			Mode:      ep.DepModes[id],
			Kind:      cur.kind,
			Iface:     cur.iface,
			Depth:     cur.depth,
			Touches:   len(cur.sites),
			Repeats:   cur.repeats,
			WireCount: len(cur.wires),
			Wires:     [][]int{},
			Sites:     []int{},
		}
		// Only when it says something the arrow does not: an equal LeadKind is the
		// common case and would be noise in every step of every route.
		if cur.leadKind != cur.kind {
			s.LeadKind = cur.leadKind
		}
		for _, w := range sortedWires(cur.wires) {
			if len(s.Wires) >= maxWires {
				break
			}
			ids := make([]int, 0, len(w.path))
			for _, name := range w.path {
				ids = append(ids, symbols.id(name))
			}
			s.Wires = append(s.Wires, ids)
		}
		for _, site := range sortedSites(cur.sites) {
			if len(s.Sites) >= maxStepSites {
				break
			}
			s.Sites = append(s.Sites, sites.id(site))
		}
		out = append(out, s)
	}
	return out
}

// leadOf is the kind of the wire an access names. Lead is set wherever an access is
// recorded, so the fallback is for an Access assembled by hand — a test, or a future
// caller building evidence outside the walk — and says what the field means: a wire
// with nothing recorded against it is the kind the access itself carries.
func leadOf(a ir.Access) string {
	if a.Lead == "" {
		return a.Kind
	}
	return a.Lead
}

// sortedWires orders a step's call paths the way the reader should read them:
// earliest first, then shortest, then alphabetically so the artifact is stable.
func sortedWires(m map[string]*wire) []*wire {
	out := make([]*wire, 0, len(m))
	for _, w := range m {
		out = append(out, w)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].order != out[j].order {
			return out[i].order < out[j].order
		}
		if len(out[i].path) != len(out[j].path) {
			return len(out[i].path) < len(out[j].path)
		}
		return strings.Join(out[i].path, "\x00") < strings.Join(out[j].path, "\x00")
	})
	return out
}

func sortedSites(m map[string]int) []string {
	out := make([]string, 0, len(m))
	for site := range m {
		out = append(out, site)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if m[out[i]] != m[out[j]] {
			return m[out[i]] < m[out[j]]
		}
		return out[i] < out[j]
	})
	return out
}
