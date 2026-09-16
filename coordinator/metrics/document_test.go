package metrics

import (
	"strings"
	"testing"
)

// TestDocumentTableRendersEveryColumn covers the shapes the real catalog does not
// happen to contain today: a type-locked gauge (nothing declares one yet — the
// `provider.mlx_*` families that need it have not migrated), a metric with no
// tags, and a mirror narrower than the metric. The rendering is what an operator
// reads out of the telemetry reference, so a column that silently stops printing
// is a fact that silently leaves the docs.
func TestDocumentTableRendersEveryColumn(t *testing.T) {
	m, _, _, _ := newFakeCatalog()
	m.lockedGauge("legacy.snapshot", "A name Datadog already stores as a gauge", "provider")
	m.counter("plain.count", "No tags at all")
	d := m.mirroredCounter("wide.count", "wide_total", "Mirror carries the first key only", "reason", "code")
	d.mirrorPrefix = 1

	table := m.DocumentTable()
	for _, want := range []string{
		"| `legacy.snapshot` | gauge (type-locked) | `provider` | — |",
		"| `plain.count` | count | — | — |",
		"| `wide.count` | count | `reason`, `code` | wide_total |",
	} {
		if !strings.Contains(table, want) {
			t.Errorf("DocumentTable() is missing the row %q; got:\n%s", want, table)
		}
	}

	docs := m.Document()
	byName := map[string]Documented{}
	for _, d := range docs {
		byName[d.Name] = d
	}
	if !byName["legacy.snapshot"].Locked {
		t.Error("a lockedGauge declaration did not report Locked")
	}
	if got := byName["wide.count"].MirrorLabels; len(got) != 1 || got[0] != "reason" {
		t.Errorf("mirror labels = %v, want [reason]: the mirror carries a prefix of the metric's keys", got)
	}
}

// TestDocumentDoesNotShareLabelBackingArrays keeps Document() from handing out a
// window onto a live declaration. Declarations are built once and then read by
// every goroutine that records a sample, so a caller that sorted or truncated the
// slice it was given would be rewriting the tag keys of a running series.
func TestDocumentDoesNotShareLabelBackingArrays(t *testing.T) {
	m, _, _, _ := newFakeCatalog()
	c := m.mirroredCounter("shared.count", "shared_total", "Two label keys", "first", "second")

	docs := m.Document()
	docs[0].Labels[0] = "clobbered"
	docs[0].MirrorLabels[0] = "clobbered"

	if c.labelKeys[0] != "first" {
		t.Errorf("declared label keys are now %v: Document() exposed the live slice", c.labelKeys)
	}
	if again := m.Document(); again[0].Labels[0] != "first" {
		t.Errorf("second Document() call returned %v", again[0].Labels)
	}
}
