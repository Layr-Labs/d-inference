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
	Roles           []json.RawMessage          `json:"roles"`
	Credentials     []json.RawMessage          `json:"credentials"`
	StateAccess     []*Edge                    `json:"stateAccess"`
	StateCoverage   Coverage                   `json:"stateCoverage"`
	CacheSemantics  map[string]json.RawMessage `json:"cacheSemantics"`
	StateModeLegend map[string]string          `json:"stateModeLegend"`
	DepDocs         map[string]json.RawMessage `json:"depDocs"`
	CategoryDocs    map[string]json.RawMessage `json:"categoryDocs"`
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

	// Evidence is the raw per-access derivation for this endpoint. It is kept
	// out of the emitted JSON (the aggregated edges carry the citations) but
	// drives assembly and tests.
	Evidence []Access `json:"-"`
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
