// Package render turns the graph into a single self-contained HTML page.
//
// The page embeds inventory.json verbatim, so the explorer and any other
// consumer read exactly the same facts, and the file can be opened from disk,
// served by GitHub Pages, or diffed in review without a build step.
package render

import (
	"bytes"
	"embed"
	"html/template"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

// The page is one HTML document with its stylesheet and its behaviour inlined,
// so the published artifact needs no second request and no build step. They are
// three files here because a thousand lines of layout and provenance logic inside
// a <script> element is not something anyone can review.
//
//go:embed page.html page.css page.js
var pageFS embed.FS

type pageData struct {
	Graph     *ir.Graph
	Revision  string
	ShortRev  string
	Routes    int
	Nodes     int
	Edges     int
	Inventory template.JS
	Drift     string
	// PageCSS and PageJS are injected verbatim. They are the generator's own
	// source, not data, so they carry the trusted types rather than going through
	// the contextual escaper — which would otherwise rewrite the JS as a string
	// literal.
	PageCSS template.CSS
	PageJS  template.JS
}

// HTML renders the explorer around the given inventory bytes.
func HTML(g *ir.Graph, inventory []byte) ([]byte, error) {
	tmpl, err := template.ParseFS(pageFS, "page.html")
	if err != nil {
		return nil, err
	}
	css, err := pageFS.ReadFile("page.css")
	if err != nil {
		return nil, err
	}
	js, err := pageFS.ReadFile("page.js")
	if err != nil {
		return nil, err
	}
	rev := g.Revision
	short := rev
	if len(short) > 12 {
		short = short[:12]
	}
	drift := "complete"
	if !g.Generator.OverlayComplete {
		drift = "drift detected — see report.md"
	}
	data := pageData{
		Graph:    g,
		Revision: rev,
		ShortRev: short,
		Routes:   len(g.Routes),
		Nodes:    len(g.Nodes),
		Edges:    len(g.StateAccess),
		// Only "</" needs neutralizing inside a JSON script block, and "\/" is
		// a valid JSON string escape, so the embedded document stays parseable.
		Inventory: template.JS(strings.ReplaceAll(string(inventory), "</", `<\/`)),
		Drift:     drift,
		PageCSS:   template.CSS(css),
		PageJS:    template.JS(js),
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
