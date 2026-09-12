package assemble

// The datastore half of assembly: publishing the derived table definitions, and
// lifting the foreign keys among them into edges the graph can draw.

import (
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/extract"
	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
)

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
		for i := range table.ForeignKeys {
			table.ForeignKeys[i].URL = blobURL(cfg, revision, table.ForeignKeys[i].Site)
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

// buildTableLinks lifts the declared foreign keys into edges between `pg.*` nodes.
//
// A key whose target the analyzed source never creates is drift, not an edge: it
// claims a relationship to a table the map has no definition for, which is the same
// failure as a query naming a table that does not exist, and it is reported the same
// way. Two other cases are silently not edges, because there is nothing to draw
// rather than something wrong: a table with no dependency node (nothing reaches it,
// so the graph has no dot for it — the key still shows in the table's own drawer),
// and a self-reference, which is one node and therefore not an edge between two.
func buildTableLinks(g *ir.Graph, rep *report.Report) {
	g.TableLinks = []*ir.TableLink{}
	for _, name := range sortedKeys(g.Tables) {
		table := g.Tables[name]
		for _, fk := range table.ForeignKeys {
			target, ok := g.Tables[fk.Table]
			if !ok {
				rep.UnknownTable(fk.Table, fk.Site)
				continue
			}
			if table.Node == "" || target.Node == "" || table.Node == target.Node {
				continue
			}
			g.TableLinks = append(g.TableLinks, &ir.TableLink{
				From:       table.Node,
				To:         target.Node,
				Columns:    fk.Columns,
				RefColumns: fk.RefColumns,
				OnDelete:   fk.OnDelete,
				OnUpdate:   fk.OnUpdate,
				Site:       fk.Site,
				URL:        fk.URL,
			})
		}
	}
}
