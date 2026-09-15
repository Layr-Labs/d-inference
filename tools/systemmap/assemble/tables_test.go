package assemble

import (
	"reflect"
	"testing"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
)

// TestBuildTableLinks covers the four answers a declared foreign key can get, three
// of which are not an edge. The fixture proves the ordinary one end to end; what needs
// isolating is the three refusals, because each is a claim the graph would otherwise
// draw and none of them can be provoked from a source tree that type-checks.
func TestBuildTableLinks(t *testing.T) {
	table := func(name, node string, fks ...ir.ForeignKey) *ir.Table {
		return &ir.Table{Name: name, Node: node, ForeignKeys: fks}
	}
	fk := func(target string, cols ...string) ir.ForeignKey {
		return ir.ForeignKey{Table: target, Columns: cols, RefColumns: []string{"id"},
			OnDelete: "CASCADE", Site: "store/store.go:42"}
	}
	g := &ir.Graph{
		Nodes: map[string]*ir.Node{"pg.usage": {}, "pg.models": {}, "pg.parents": {}},
		Tables: map[string]*ir.Table{
			// The ordinary case, and the self-reference beside it: one node, so there is
			// no edge between two even though the key is real and shows in the drawer.
			"usage": table("usage", "pg.usage", fk("models", "model_id"), fk("usage", "parent_id"),
				// A target nothing creates. The map has no definition for it, so an edge
				// would be an arrow into a table that does not exist.
				fk("archive", "archive_id"),
				// A target that exists but that nothing reaches, so the graph has no dot
				// to draw the arrow to.
				fk("quotas", "quota_id")),
			"models": table("models", "pg.models"),
			"quotas": table("quotas", ""),
			// A referencing table with no node of its own: same silence, other end.
			"orphan": table("orphan", "", fk("models", "model_id")),
		},
	}
	rep := report.New()
	buildTableLinks(g, rep)

	type link struct{ from, to, col string }
	var got []link
	for _, l := range g.TableLinks {
		got = append(got, link{l.From, l.To, l.Columns[0]})
	}
	want := []link{{"pg.usage", "pg.models", "model_id"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("links = %+v, want %+v", got, want)
	}
	// Only the key whose target has no definition is drift, and it is reported against
	// the table it named and cited where it was declared.
	if sites := rep.UnknownTables["archive"]; !reflect.DeepEqual(sites, []string{"store/store.go:42"}) {
		t.Errorf("archive reported at %v, want the key's own site", sites)
	}
	if len(rep.UnknownTables) != 1 {
		t.Errorf("reported %v; a key that simply has no dot to point at is not drift", rep.UnknownTables)
	}
	// The published field is a list either way: a graph with no relationships must
	// serialize as [] and not as null, or the page has to guard every read of it.
	empty := &ir.Graph{Nodes: map[string]*ir.Node{}, Tables: map[string]*ir.Table{}}
	buildTableLinks(empty, report.New())
	if empty.TableLinks == nil {
		t.Error("a schema with no foreign keys published a nil link list")
	}
}
