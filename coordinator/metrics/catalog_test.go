package metrics

import (
	"bufio"
	"os"
	"regexp"
	"strings"
	"testing"
)

// nameShape is what a DogStatsD metric name and a tag key may contain. Anything
// else is either silently rewritten by the intake or produces a series nobody
// can query by hand.
var nameShape = regexp.MustCompile(`^[a-z0-9]+([._][a-z0-9]+)*$`)

// TestCatalogIsWellFormed builds the catalog, which is also the only guard that
// keeps New's duplicate-name panic from ever reaching a running process: the
// declarations are static, so if this test constructs them without panicking,
// nothing at runtime can.
func TestCatalogIsWellFormed(t *testing.T) {
	m := Noop()
	docs := m.Document()
	if len(docs) == 0 {
		t.Fatal("the catalog declared nothing")
	}
	for _, d := range docs {
		if !nameShape.MatchString(d.Name) {
			t.Errorf("%q is not a usable metric name", d.Name)
		}
		if strings.TrimSpace(d.Help) == "" {
			t.Errorf("%s has no help text; Document() is what an operator reads instead of grepping", d.Name)
		}
		seen := map[string]bool{}
		for _, key := range d.Labels {
			if !nameShape.MatchString(key) {
				t.Errorf("%s: tag key %q is not usable", d.Name, key)
			}
			if seen[key] {
				t.Errorf("%s declares tag key %q twice", d.Name, key)
			}
			seen[key] = true
		}
		if d.Kind == KindGauge && d.Mirror != "" {
			t.Errorf("%s is a mirrored gauge: the in-process registry has no gauge sink for a pushed value", d.Name)
		}
	}
}

// TestDeclaredNamesAlreadyExist is the guard that makes this migration
// non-destructive. Every name in the catalog must be a name the coordinator was
// already emitting before the catalog existed (testdata/emitted_names.txt,
// extracted from the call sites it replaces). A typo in a declaration would
// otherwise create a new series and silently retire a dashboard's series, and
// nothing else in the build would notice.
//
// The check is one-directional on purpose: names not yet migrated are still
// emitted from their old call sites. It becomes an equality check when the last
// shim is deleted.
func TestDeclaredNamesAlreadyExist(t *testing.T) {
	emitted := readNameList(t, "testdata/emitted_names.txt")
	mirrors := readNameList(t, "testdata/mirror_names.txt")
	for _, d := range Noop().Document() {
		if !emitted[d.Name] {
			t.Errorf("%q is not a name the coordinator emitted before the catalog; a rename retires the existing series", d.Name)
		}
		if d.Mirror != "" && !mirrors[d.Mirror] {
			t.Errorf("%q mirrors to %q, which is not an existing in-process metric name", d.Name, d.Mirror)
		}
	}
}

func readNameList(t *testing.T, path string) map[string]bool {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	names := map[string]bool{}
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		if name := strings.TrimSpace(scan.Text()); name != "" {
			names[name] = true
		}
	}
	if err := scan.Err(); err != nil {
		t.Fatal(err)
	}
	return names
}

// TestInventoryDocMatchesTheCatalog is the docs-drift guard. The declared table
// in the telemetry inventory is generated (go run ./metrics/cmd/metricdoc), and
// a metric whose tags or type change in code but not in the docs is exactly how
// that page drifted from the coordinator before the catalog existed.
//
// Fix a failure by regenerating the block, not by editing this test:
//
//	cd coordinator && go run ./metrics/cmd/metricdoc
func TestInventoryDocMatchesTheCatalog(t *testing.T) {
	const path = "../../docs/reference/telemetry-inventory.md"
	doc, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	table := Noop().DocumentTable()
	if !strings.Contains(string(doc), strings.TrimRight(table, "\n")) {
		t.Errorf("%s does not contain the generated declaration table; regenerate it with\n"+
			"\tcd coordinator && go run ./metrics/cmd/metricdoc", path)
	}
}

// TestDocumentTableCoversEveryDeclaration keeps the rendered form usable: it is
// what the telemetry reference is checked against, so a metric missing from it
// is a metric nobody documents.
func TestDocumentTableCoversEveryDeclaration(t *testing.T) {
	m := Noop()
	table := m.DocumentTable()
	for _, d := range m.Document() {
		if !strings.Contains(table, "`"+d.Name+"`") {
			t.Errorf("%s is missing from DocumentTable()", d.Name)
		}
	}
}
