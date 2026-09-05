// Package ir defines the service-agnostic intermediate representation the
// system map is built from.
//
// One extractor per language populates this schema (the coordinator's Go
// extractor is the first); the assembler merges extractor output with the
// curated overlay, and the renderer turns it into the explorer. Adding a
// service means adding an extractor, not changing this schema.
//
// JSON field names are stable: they are the contract between the generator and
// any consumer of inventory.json.
package ir

import (
	"bytes"
	"encoding/json"
)

// Graph is the whole generated artifact.
type Graph struct {
	Revision        string                     `json:"revision"`
	Generator       Generator                  `json:"generator"`
	Services        []*Service                 `json:"services"`
	Routes          []*Endpoint                `json:"routes"`
	Clusters        map[string]Cluster         `json:"clusters"`
	Groups          map[string]*Group          `json:"groups"`
	Categories      map[string]Category        `json:"categories"`
	Labels          map[string]string          `json:"labels"`
	Nodes           map[string]*Node           `json:"nodes"`
	Tables          map[string]*Table          `json:"tables"`
	TableLinks      []*TableLink               `json:"tableLinks"`
	Roles           []json.RawMessage          `json:"roles"`
	Credentials     []json.RawMessage          `json:"credentials"`
	StateAccess     []*Edge                    `json:"stateAccess"`
	StateCoverage   Coverage                   `json:"stateCoverage"`
	CacheSemantics  map[string]json.RawMessage `json:"cacheSemantics"`
	StateModeLegend map[string]string          `json:"stateModeLegend"`
	StepKindLegend  map[string]string          `json:"stepKindLegend"`
	DepDocs         map[string]json.RawMessage `json:"depDocs"`
	CategoryDocs    map[string]json.RawMessage `json:"categoryDocs"`

	// Symbols and Sites are interning tables for the wiring steps: a call path
	// repeats the same function labels across a hundred endpoints, and a citation
	// repeats across every step that shares it. Steps reference them by index, which
	// is what keeps per-endpoint call paths affordable in a single-file artifact.
	Symbols []string `json:"symbols"`
	Sites   []string `json:"sites"`
}

// Generator records how the artifact was produced, so a reader can tell derived
// facts from curated prose.
type Generator struct {
	Tool            string `json:"tool"`
	Derived         string `json:"derived"`
	Curated         string `json:"curated"`
	Overlay         string `json:"overlay"`
	OverlayComplete bool   `json:"overlayComplete"`
}

// Service is one extracted component of the system.
type Service struct {
	ID       string `json:"id"`       // "coordinator"
	Title    string `json:"title"`    // "Coordinator control plane"
	Language string `json:"language"` // "go"
	Root     string `json:"root"`     // "coordinator"
	Routes   int    `json:"routes"`
}

// Endpoint is one externally reachable entry point (an HTTP route today; a
// WebSocket frame or CLI command when other extractors land).
type Endpoint struct {
	ID             int      `json:"id"`
	Service        string   `json:"service"`
	Method         string   `json:"method"`
	Path           string   `json:"path"`
	RegisteredPath string   `json:"registeredPath"`
	Handler        string   `json:"handler"`
	Namespace      string   `json:"namespace"`
	Auth           string   `json:"auth"`
	AuthDetail     string   `json:"authDetail"`
	Middleware     []string `json:"middleware"`
	Gates          []string `json:"gates"`
	Description    string   `json:"description"`
	Details        string   `json:"details,omitempty"`
	RouteLine      int      `json:"routeLine"`
	RouteFile      string   `json:"routeFile"`
	Source         string   `json:"source"`
	SourceURL      string   `json:"sourceUrl,omitempty"`
	RouteURL       string   `json:"routeUrl,omitempty"`
	Dependencies   []string `json:"dependencies"`
	Callers        []string `json:"callers"`
	Caller         string   `json:"caller,omitempty"`

	// Group is the sub-boundary this endpoint is drawn inside (its namespace).
	Group string `json:"group"`
	// DepModes is this endpoint's own access mode per dependency, derived from
	// its evidence — not the namespace aggregate.
	DepModes map[string]string `json:"depModes"`

	// Flow is the wiring: one step per construction this endpoint reaches, in the
	// order the walk first reaches it, with the call path that gets there and how
	// the call is indirected. Dependencies answers *what* a route touches; Flow
	// answers *in what order, through what, and how often*.
	Flow []Step `json:"flow,omitempty"`

	// Evidence is the raw per-access derivation for this endpoint. It is kept
	// out of the emitted JSON (the aggregated edges carry the citations) but
	// drives assembly and tests.
	Evidence []Access `json:"-"`
}

// Step is one hop of an endpoint's wiring: the construction it touches, where in
// the call order that touch first happens, the path that reaches it, and how many
// distinct places in reachable code touch it.
//
// The order is static — the sequence the type-checked call graph is walked in, not
// a runtime trace. It is the order a reader following the source would meet these
// constructions, which is the question "what does this endpoint do first" has an
// answer to without running anything. Touches is likewise a count of distinct
// source sites, not of executions; Repeats is the only thing that says a site can
// run more than once.
type Step struct {
	Seq  int    `json:"seq"`  // 1..n, first-touch order along the walk
	Node string `json:"node"` // dependency node id
	Mode string `json:"mode"` // this endpoint's merged access mode for the node

	// Kind is the strongest indirection over *all* of this endpoint's touches of the
	// node, which is the weakest claim its timing supports: a construction written
	// to from a goroutine is touched concurrently even if the read that comes first
	// is a plain call. LeadKind is the indirection of the earliest touch — the one
	// Depth, Wires[0] and Sites[0] belong to — and is set only when it differs, so a
	// reader is told when the path printed beside the arrow is not the path the arrow
	// is about. Iface is the off-ladder axis: see Access.Iface.
	Kind     string `json:"kind"` // see StepKindLegend
	LeadKind string `json:"leadKind,omitempty"`
	Iface    bool   `json:"iface,omitempty"`
	Depth    int    `json:"depth"`

	Touches int  `json:"touches"`           // distinct source sites that touch the node
	Repeats bool `json:"repeats,omitempty"` // at least one touch is inside a loop

	// Wires are the call paths that reach the node, each a list of Graph.Symbols
	// indices running from the handler to the function that touches it, ordered by
	// first touch and capped.
	//
	// WireCount is how many distinct paths reach the node among the touches the walk
	// *kept*, which is a floor and not a census: every frame collapses its evidence
	// by (node, mode, site, innermost function) and keeps the earliest path, so a
	// line reached two ways through the same immediate caller publishes one path
	// rather than two. What the number answers is "how many ways does the map have to
	// show me", which is the question the capped Wires beside it raises.
	Wires     [][]int `json:"wires"`
	WireCount int     `json:"wireCount"`

	// Sites are Graph.Sites indices for the touch citations, capped.
	Sites []int `json:"sites"`
}

// Node is a dependency the system depends on: a Postgres table, a piece of
// in-memory coordinator state, an external service, or a protocol surface.
type Node struct {
	ID       string `json:"id"`
	Category string `json:"category"`
	Label    string `json:"label"`
	Group    string `json:"group"`   // the sub-boundary it is drawn inside (its category)
	Derived  bool   `json:"derived"` // true when source evidence produced this node
	Reached  bool   `json:"reached"` // true when some endpoint reaches it

	// NamedBy records which mapping tables give this node its identity, sorted:
	// "sql" when source itself declares the name (a CREATE TABLE), "hosts",
	// "endpoints" or "messages" when a curated name is bound to a literal the
	// compiler found, and "fields", "types" or "functions" when it is bound to a
	// symbol. It answers how much of the node's identity a person invented, which
	// is a different question from whether the node is reached.
	NamedBy []string `json:"namedBy,omitempty"`
}

// Group is a sub-boundary drawn inside a cluster, directly around the nodes
// themselves: one per endpoint namespace and one per dependency category. It is
// entirely derived — the namespaces come from the route table via the overlay's
// namespace rules, the categories from the node taxonomy — so a new namespace or
// category becomes a new sub-boundary with no renderer change.
type Group struct {
	ID      string `json:"id"`
	Cluster string `json:"cluster"`
	Title   string `json:"title"`
	Kind    string `json:"kind"` // "namespace" or "category"
	Color   string `json:"color,omitempty"`
	Desc    string `json:"desc,omitempty"`
	Members int    `json:"members"`
}

// Table is the derived definition of one datastore table: its columns, its
// table-level constraints, and the DDL statements that produce it. A table's real
// shape is the CREATE plus the ALTER migrations that grew it, which is why the
// columns are collected from both and each carries its own citation.
type Table struct {
	Name        string       `json:"name"`
	Node        string       `json:"node,omitempty"` // the dependency node, when one exists
	Columns     []Column     `json:"columns"`
	Constraints []Constraint `json:"constraints,omitempty"`
	ForeignKeys []ForeignKey `json:"foreignKeys,omitempty"`
	DDL         []Statement  `json:"ddl"`
}

// Column is one column as source declares it.
type Column struct {
	Name string `json:"name"`
	Type string `json:"type"`
	// Extra is the rest of the definition: nullability, default, inline
	// constraints, as written.
	Extra string `json:"extra,omitempty"`
	// Migration is true when an `ALTER TABLE ... ADD COLUMN` introduced the
	// column rather than the original CREATE.
	Migration bool   `json:"migration,omitempty"`
	Site      string `json:"site"`
	URL       string `json:"url,omitempty"`
}

// Constraint is a table-level constraint (primary key, unique, check, foreign
// key) as written.
type Constraint struct {
	Text string `json:"text"`
	Site string `json:"site"`
	URL  string `json:"url,omitempty"`
}

// Statement is one DDL statement, as written and where.
type Statement struct {
	Kind string `json:"kind"` // "create", "alter" or "index"
	SQL  string `json:"sql"`
	Site string `json:"site"`
	URL  string `json:"url,omitempty"`
}

// Category groups nodes into the explorer's columns.
type Category struct {
	Title   string `json:"title"`
	Color   string `json:"color"`
	Desc    string `json:"desc"`
	Cluster string `json:"cluster"`
}

// Cluster is a boundary the explorer draws around nodes: one of the system's own
// processes, a datastore it owns, or a third party it talks to. A dependency node
// joins the cluster its category names; an endpoint namespace joins the cluster
// named after the service that serves it. That indirection is what lets a second
// extractor add its own process boundary without touching the renderer.
type Cluster struct {
	Title string `json:"title"`
	Kind  string `json:"kind"` // "service", "datastore" or "external"
	Color string `json:"color"`
	Desc  string `json:"desc,omitempty"`
}

// Access is one piece of evidence that an endpoint's reachable code touches a
// node.
type Access struct {
	Node string `json:"node"`
	Mode string `json:"mode"` // "R", "W" or "RW"
	Site string `json:"site"` // "coordinator/store/postgres.go:3915"
	Via  string `json:"via"`  // evidencing symbol, e.g. "store.PostgresStore.GetLatestRelease"

	// The ordering half of the derivation, all of it internal to assembly (the
	// emitted artifact carries it folded into Endpoint.Flow).
	//
	// Order is the position of this access in the walk of the endpoint it belongs
	// to: each frame numbers its own accesses as it meets them, and a callee's
	// numbers are shifted to sit where the call site was, so the sequence reads as
	// pre-order over the call graph. Path names the callers above Via, handler
	// first, so Path+Via is the wire. Kind is the strongest indirection anywhere on
	// that wire and Loop is true when any hop of it sits in a loop body.
	//
	// Iface is the one indirection that is not a claim about *when* the touch
	// happens, so it does not fit the Kind ladder and is carried beside it: true
	// when some hop of this wire dispatched through an interface, whether or not a
	// `go` or `defer` further along outranked it.
	//
	// Lead is the kind of the wire Path names, which is not always Kind: when two
	// entries are the same line reached twice, the survivor keeps the earlier one's
	// path and the stronger one's kind, and only Lead still describes the path. It is
	// what Step.LeadKind is published from, so an arrow that says "goroutine" is
	// never printed over a wire with no `go` on it without saying so.
	Order int      `json:"-"`
	Depth int      `json:"-"`
	Kind  string   `json:"-"`
	Lead  string   `json:"-"`
	Iface bool     `json:"-"`
	Loop  bool     `json:"-"`
	Path  []string `json:"-"`
}

// How a call is indirected. A wire carries the strongest kind on it, because that
// is the weakest claim the reader can make about when the touch happens: a direct
// call inside a goroutine is not a direct call from the handler's point of view.
//
// Three of the four are that one claim, about *when*. StepInterface is not — it says
// the walk chose which body to read — so ranking it on the same ladder means a wire
// that both dispatches through an interface and runs in a `defer` can only publish
// one of the two. It publishes the timing, and the dispatch travels beside it as
// Access.Iface / Step.Iface so nothing is lost.
const (
	StepDirect    = "direct"
	StepInterface = "interface"
	StepDeferred  = "deferred"
	StepAsync     = "async"
)

// stepKindRank orders the kinds by how far they push a touch away from the
// handler's own straight line.
var stepKindRank = map[string]int{
	StepDirect: 1, StepInterface: 2, StepDeferred: 3, StepAsync: 4,
}

// StrongerKind returns whichever of two indirection kinds makes the weaker claim
// about when the touch happens. An empty kind loses to anything.
func StrongerKind(a, b string) string {
	if stepKindRank[b] > stepKindRank[a] {
		return b
	}
	if a == "" {
		return StepDirect
	}
	return a
}

// StepKindLegend explains the arrow vocabulary, and ships inside the artifact so
// the explorer and any other consumer read the same definitions.
var StepKindLegend = map[string]string{
	StepDirect:    "Every hop from the handler to this construction is a direct, statically resolved call.",
	StepInterface: "Some hop dispatches through an interface; the walk followed the implementation the overlay prefers, so the running program may reach a different one.",
	StepDeferred:  "Some hop runs in a deferred call, so the touch happens as its frame unwinds rather than where it is written.",
	StepAsync:     "Some hop runs in a goroutine, so the touch is concurrent with the rest of the request and unordered against it.",
}

// ForeignKey is one declared referential constraint, as source writes it.
type ForeignKey struct {
	Name       string   `json:"name,omitempty"`       // CONSTRAINT name, when one is given
	Columns    []string `json:"columns"`              // referencing columns
	Table      string   `json:"table"`                // referenced table
	RefColumns []string `json:"refColumns,omitempty"` // referenced columns, when named
	OnDelete   string   `json:"onDelete,omitempty"`
	OnUpdate   string   `json:"onUpdate,omitempty"`
	Site       string   `json:"site"`
	URL        string   `json:"url,omitempty"`
}

// TableLink is one foreign key lifted to the graph: an edge between two `pg.*`
// dependency nodes. It exists separately from Table.ForeignKeys because the graph
// draws node ids, and because a key whose target the analyzed source never creates
// is reported rather than drawn.
type TableLink struct {
	From       string   `json:"from"` // referencing node id, e.g. "pg.api_keys"
	To         string   `json:"to"`   // referenced node id
	Columns    []string `json:"columns"`
	RefColumns []string `json:"refColumns,omitempty"`
	OnDelete   string   `json:"onDelete,omitempty"`
	OnUpdate   string   `json:"onUpdate,omitempty"`
	Site       string   `json:"site"`
	URL        string   `json:"url,omitempty"`
}

// Edge is one namespace→node association with its access mode.
type Edge struct {
	Namespace  string   `json:"namespace"`
	Dependency string   `json:"dependency"`
	Mode       string   `json:"mode"`
	Reason     string   `json:"reason"`
	Routes     []string `json:"routes"`
	Citations  []string `json:"citations"`
}

// Coverage summarizes the edge set.
type Coverage struct {
	PostgresAssociations int            `json:"postgres_associations"`
	InMemoryAssociations int            `json:"in_memory_associations"`
	TotalAssociations    int            `json:"total_associations"`
	Classified           int            `json:"classified"`
	Ambiguous            int            `json:"ambiguous"`
	ModeCounts           map[string]int `json:"mode_counts"`
}

// Access modes. Every association carries one.
const (
	ModeRead    = "R"
	ModeWrite   = "W"
	ModeBoth    = "RW"
	ModeUnknown = "?"
)

// ModeLegend explains the R/W/RW/? vocabulary. It ships inside the artifact so
// the explorer and any other consumer read the same definitions.
var ModeLegend = map[string]string{
	"R":  "Only lookup, select, snapshot, or state inspection is evidenced in reachable code.",
	"W":  "Only insertion, mutation, invalidation, enqueue, counter update, or state transition is evidenced.",
	"RW": "Both reads and writes are evidenced, including cache lookup plus fill/update/invalidation.",
	"?":  "A node the overlay declares that no reachable endpoint code touches.",
}

// Marshal renders the graph as stable, human-diffable JSON.
func (g *Graph) Marshal() ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(g); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
