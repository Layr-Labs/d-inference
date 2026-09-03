// Package report accumulates everything the extractor found that the overlay
// does not explain, plus overlay entries that no longer match source.
//
// This is the drift detector: `systemmap -check` fails on a non-empty report, so
// a new route, a new piece of coordinator state, a new table or a renamed
// handler surfaces in CI instead of quietly rotting in a published page.
package report

import (
	"fmt"
	"sort"
	"strings"
)

type Report struct {
	UnmappedFields map[string]*Finding
	AbsorbedTypes  map[string]*Holder
	OpaqueQueries  map[string]*OpaqueQuery
	UnknownTables  map[string][]string
	UnknownHosts   map[string][]string
	MissingLabels  map[string]bool
	MissingProse   []string
	UndocumentedN  []string
	UndefinedTable []string
	StaleProse     []string
	Unclassified   []string
	BadClusters    []string
	Unreached      []string
}

type Finding struct {
	Package string
	Struct  string
	Field   string
	Type    string
	Sites   []string
}

// Holder is a concurrent-state type that no overlay entry names: reachable from an
// endpoint, but explained only by a package-wide rule.
type Holder struct {
	Package string
	Struct  string
	Field   string // the field that makes it concurrent state ("mu", "inner.mu")
	Type    string // that field's type ("sync.RWMutex", "chan struct{}")
	Via     string // the rule that absorbed it ("deps.packageDefault")
	Site    string
}

// OpaqueQuery is statement text the extractor could not read. The map's table
// edges come from that text, so text it cannot read is state the map silently
// omits — no unknown table, no unmapped field, nothing for the other checks to
// catch. One entry per site, because two of these in one body are two problems.
type OpaqueQuery struct {
	Package string
	Func    string
	Detail  string // what was unreadable, in the report's own words
	Remedy  string // what to do about it, when the detail does not say so itself
	Site    string
}

func New() *Report {
	return &Report{
		UnmappedFields: map[string]*Finding{},
		AbsorbedTypes:  map[string]*Holder{},
		OpaqueQueries:  map[string]*OpaqueQuery{},
		UnknownTables:  map[string][]string{},
		UnknownHosts:   map[string][]string{},
		MissingLabels:  map[string]bool{},
	}
}

// OpaqueQuery records statement text the extractor could not read, keyed by the
// site so that two findings in one body — or in two closures the walker labels
// alike — stay two findings. The remedy is separate from the detail because not
// every finding here has the same one: a declaration that no longer matches its
// source is not fixed by rewriting a statement.
func (r *Report) OpaqueQuery(pkgRel, fn, site, detail, remedy string) {
	if _, ok := r.OpaqueQueries[site]; ok {
		return
	}
	r.OpaqueQueries[site] = &OpaqueQuery{Package: pkgRel, Func: fn, Detail: detail, Remedy: remedy, Site: site}
}

// AbsorbedState records a concurrent-state struct that a package-wide rule
// swallowed. See extract/holders.go for why the criterion is what it is.
func (r *Report) AbsorbedState(pkgRel, structName, field, typ, via, site string) {
	key := pkgRel + ":" + structName
	if _, ok := r.AbsorbedTypes[key]; ok {
		return
	}
	r.AbsorbedTypes[key] = &Holder{
		Package: pkgRel, Struct: structName, Field: field, Type: typ, Via: via, Site: site,
	}
}

func (r *Report) UnmappedField(pkgRel, structName, field, typ, site string) {
	key := pkgRel + ":" + structName + "." + field
	f, ok := r.UnmappedFields[key]
	if !ok {
		f = &Finding{Package: pkgRel, Struct: structName, Field: field, Type: typ}
		r.UnmappedFields[key] = f
	}
	if len(f.Sites) < 3 && !contains(f.Sites, site) {
		f.Sites = append(f.Sites, site)
	}
}

func (r *Report) UnknownTable(table, site string) {
	if len(r.UnknownTables[table]) < 3 && !contains(r.UnknownTables[table], site) {
		r.UnknownTables[table] = append(r.UnknownTables[table], site)
	}
}

func (r *Report) UnknownHost(host, site string) {
	if len(r.UnknownHosts[host]) < 3 && !contains(r.UnknownHosts[host], site) {
		r.UnknownHosts[host] = append(r.UnknownHosts[host], site)
	}
}

func (r *Report) MissingLabel(node string) { r.MissingLabels[node] = true }
func (r *Report) AddMissingProse(s string) { r.MissingProse = append(r.MissingProse, s) }
func (r *Report) AddUndocumented(s string) { r.UndocumentedN = append(r.UndocumentedN, s) }
func (r *Report) AddUndefinedTable(s string) {
	r.UndefinedTable = append(r.UndefinedTable, s)
}
func (r *Report) AddStaleProse(s string)    { r.StaleProse = append(r.StaleProse, s) }
func (r *Report) AddUnclassified(s string)  { r.Unclassified = append(r.Unclassified, s) }
func (r *Report) AddBadCluster(s string)    { r.BadClusters = append(r.BadClusters, s) }
func (r *Report) AddUnreachedNode(s string) { r.Unreached = append(r.Unreached, s) }

// Clean reports whether source and overlay agree completely.
func (r *Report) Clean() bool {
	return len(r.UnmappedFields) == 0 && len(r.AbsorbedTypes) == 0 && len(r.OpaqueQueries) == 0 &&
		len(r.UnknownTables) == 0 &&
		len(r.UnknownHosts) == 0 && len(r.MissingLabels) == 0 && len(r.MissingProse) == 0 &&
		len(r.UndocumentedN) == 0 && len(r.UndefinedTable) == 0 && len(r.StaleProse) == 0 &&
		len(r.Unclassified) == 0 && len(r.BadClusters) == 0
}

// Counts summarizes the report for a one-line status.
func (r *Report) Counts() string {
	return fmt.Sprintf("%d unmapped state, %d absorbed concurrent types, %d unreadable statements, %d unknown tables, %d unknown hosts, %d unlabeled nodes, %d undocumented nodes, %d undefined tables, %d routes missing prose, %d stale prose, %d unclassified, %d cluster problems",
		len(r.UnmappedFields), len(r.AbsorbedTypes), len(r.OpaqueQueries), len(r.UnknownTables), len(r.UnknownHosts),
		len(r.MissingLabels), len(r.UndocumentedN), len(r.UndefinedTable), len(r.MissingProse), len(r.StaleProse),
		len(r.Unclassified), len(r.BadClusters))
}

// Markdown renders the drift report.
func (r *Report) Markdown() string {
	var b strings.Builder
	b.WriteString("# systemmap drift report\n\n")
	b.WriteString("Generated by `make -C tools/systemmap`. Every entry below is something\n")
	b.WriteString("source states that `docs/reference/api-map/overlay.json` does not explain — or\n")
	b.WriteString("the reverse. An empty report means the map is complete; `-check` fails when it\n")
	b.WriteString("is not.\n\n")

	section := func(title, empty string, lines []string) {
		b.WriteString("## " + title + "\n\n")
		if len(lines) == 0 {
			b.WriteString(empty + "\n\n")
			return
		}
		for _, line := range lines {
			b.WriteString("- " + line + "\n")
		}
		b.WriteString("\n")
	}

	var fields []string
	for _, key := range keys(r.UnmappedFields) {
		f := r.UnmappedFields[key]
		fields = append(fields, fmt.Sprintf("`%s` (type `%s`) — reachable from a handler but absent from `deps.fields`; first seen at %s",
			key, f.Type, strings.Join(f.Sites, ", ")))
	}
	section("State reachable from endpoints with no dependency node", "None — every reachable field maps to a node.", fields)

	var holders []string
	for _, key := range keys(r.AbsorbedTypes) {
		h := r.AbsorbedTypes[key]
		holders = append(holders, fmt.Sprintf("`%s` — concurrent state (`%s %s`) reachable from an endpoint, but only `%s` explains it; give it a `deps.types` node or say `@skip` on purpose; reached at %s",
			key, h.Field, h.Type, h.Via, h.Site))
	}
	section("Concurrent in-memory types absorbed by a package-wide rule",
		"None — every mutex-, atomic- or channel-bearing type an endpoint reaches is named.", holders)

	var opaque []string
	for _, key := range keys(r.OpaqueQueries) {
		q := r.OpaqueQueries[key]
		line := fmt.Sprintf("`%s:%s` — %s", q.Package, q.Func, q.Detail)
		if q.Remedy != "" {
			line += ", " + q.Remedy
		}
		opaque = append(opaque, line+"; "+key)
	}
	section("Statement text the extractor cannot read",
		"None — every statement resolves to a literal or a constant, and no fragment names a table on its own.", opaque)

	var tables []string
	for _, name := range keys(r.UnknownTables) {
		tables = append(tables, fmt.Sprintf("`%s` — named in SQL but no matching `CREATE TABLE`; %s",
			name, strings.Join(r.UnknownTables[name], ", ")))
	}
	section("SQL table references with no schema match", "None — every table in a query exists in the schema.", tables)

	var hosts []string
	for _, name := range keys(r.UnknownHosts) {
		hosts = append(hosts, fmt.Sprintf("`%s` — external host with no `deps.hosts` node; %s",
			name, strings.Join(r.UnknownHosts[name], ", ")))
	}
	section("External hosts with no dependency node", "None — every outbound host maps to a node.", hosts)

	var labels []string
	for _, node := range keys(r.MissingLabels) {
		labels = append(labels, fmt.Sprintf("`%s` — derived node with no `labels` entry", node))
	}
	section("Dependency nodes missing a label", "None — every derived node is labeled.", labels)
	section("Dependency nodes missing curated prose", "None — every node the graph draws is explained.", sortCopy(r.UndocumentedN))

	section("Postgres nodes with no table definition",
		"None — every `pg.*` node has a `CREATE TABLE` in source.", sortCopy(r.UndefinedTable))

	section("Routes missing curated prose", "None — every route has a description.", sortCopy(r.MissingProse))
	section("Overlay prose for routes that no longer exist", "None — no stale entries.", sortCopy(r.StaleProse))
	section("Routes with no namespace or auth rule", "None — every route is classified.", sortCopy(r.Unclassified))
	section("Nodes the graph cannot place in a boundary", "None — every service and category names a declared cluster.", sortCopy(r.BadClusters))
	b.WriteString("The final section is informational: the map is scoped to HTTP entry points, so a\n")
	b.WriteString("surface only a background worker touches is declared and labeled but has no\n")
	b.WriteString("endpoint edge. Overlay claims about those surfaces are still checked against\n")
	b.WriteString("source above.\n\n")
	section("Declared nodes no endpoint reaches", "None — every declared node is reached.", sortCopy(r.Unreached))
	return b.String()
}

func keys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortCopy(in []string) []string {
	out := append([]string{}, in...)
	sort.Strings(out)
	return out
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}
