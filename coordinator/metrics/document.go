package metrics

import (
	"fmt"
	"slices"
	"sort"
	"strings"
)

// Documented is one declaration as an operator sees it. Document() exists so
// "what does this coordinator emit" is answerable from the binary rather than by
// grepping for call sites, and so the reference table in the docs can be checked
// against the code instead of drifting from it.
type Documented struct {
	// Name is the DogStatsD name without the `d_inference.` namespace.
	Name string
	// Mirror is the in-process registry name, empty when the metric has none.
	Mirror string
	// MirrorLabels are the labels the mirror carries, which may be a prefix of
	// Labels.
	MirrorLabels []string
	Kind         Kind
	Labels       []string
	Help         string
	// Locked marks a name whose type is pinned by what Datadog already stores
	// rather than chosen — see lockedGauge.
	Locked bool
}

// Document returns every declaration, sorted by name. The label slices are
// copies: a declaration is immutable once built and read by every goroutine that
// records a sample, so handing out the live backing array would let a caller
// rewrite the tag keys of a series under the collectors emitting it.
func (m *Metrics) Document() []Documented {
	out := make([]Documented, 0, len(m.declared))
	for _, d := range m.declared {
		doc := Documented{
			Name:   d.name,
			Mirror: d.mirror,
			Kind:   d.kind,
			Labels: slices.Clone(d.labelKeys),
			Help:   d.help,
			Locked: d.locked,
		}
		if d.mirror != "" {
			keys := d.labelKeys
			if d.mirrorPrefix > 0 && d.mirrorPrefix < len(keys) {
				keys = keys[:d.mirrorPrefix]
			}
			doc.MirrorLabels = slices.Clone(keys)
		}
		out = append(out, doc)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// DocumentTable renders Document() as a markdown table, which is the form the
// telemetry reference wants and the form a reviewer can diff.
func (m *Metrics) DocumentTable() string {
	var b strings.Builder
	b.WriteString("| Metric | Type | Tags | Mirror | Help |\n|---|---|---|---|---|\n")
	for _, d := range m.Document() {
		kind := string(d.Kind)
		if d.Locked {
			kind += " (type-locked)"
		}
		mirror := d.Mirror
		if mirror == "" {
			mirror = "—"
		}
		labels := "—"
		if len(d.Labels) > 0 {
			labels = "`" + strings.Join(d.Labels, "`, `") + "`"
		}
		fmt.Fprintf(&b, "| `%s` | %s | %s | %s | %s |\n", d.Name, kind, labels, mirror, d.Help)
	}
	return b.String()
}
