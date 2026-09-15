package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// TestPageExecutes runs the committed DOM suite (render/webtest) against a freshly
// rendered fixture page.
//
// The rest of the page tests in this package assert about the *text* of the
// artifact: that a control is in the markup, that a function the explorer needs was
// emitted. That is worth having — it is what catches a template that stopped
// injecting the script — but it cannot tell whether the script runs, whether the
// filters agree with the inventory, or whether two labels are drawn on top of each
// other. So the same artifact is loaded into a DOM and driven, and this test is how
// `go test` reaches that: one Go test, one `node --test`, the failures reported
// through the Go runner like any other.
//
// It skips when Node or the suite's dependencies are absent, because a Go-only
// checkout must still be able to run `go test ./...`. CI sets SYSTEMMAP_WEBTEST=1,
// which turns every one of those skips into a failure — the suite is only a gate if
// something insists it actually ran.
func TestPageExecutes(t *testing.T) {
	required := os.Getenv("SYSTEMMAP_WEBTEST") == "1"
	absent := func(format string, args ...any) {
		t.Helper()
		if required {
			t.Fatalf(format, args...)
		}
		t.Skipf(format, args...)
	}

	node, err := exec.LookPath("node")
	if err != nil {
		absent("node is not on PATH, so the explorer cannot be executed: %v", err)
	}
	dir, err := filepath.Abs("render/webtest")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "node_modules", "jsdom")); err != nil {
		absent("jsdom is not installed: %v (run `make -C tools/systemmap webdeps`)", err)
	}

	// Every file the suite is made of, discovered rather than listed, and read here
	// rather than only in the subprocess.
	//
	// Read here, because Go's test cache keys on what the test *process* opens and a
	// subprocess's reads are invisible to it: without this, editing a .mjs file and
	// re-running `go test` replays a cached PASS without running the suite again.
	//
	// Discovered, because a hardcoded list is a second place to remember: a new
	// `*.test.mjs` would run in the subprocess and go uncounted here, and a new helper
	// would not key the cache. package.json is added by name — it is the only file the
	// suite needs that is not a module.
	files, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	suite := []string{"package.json"}
	var tests []string
	for _, f := range files {
		if f.IsDir() || !strings.HasSuffix(f.Name(), ".mjs") {
			continue
		}
		suite = append(suite, f.Name())
		if strings.HasSuffix(f.Name(), ".test.mjs") {
			tests = append(tests, f.Name())
		}
	}
	if len(tests) == 0 {
		t.Fatal("render/webtest contains no *.test.mjs, so there is nothing to run")
	}
	wantTests := 0
	for _, name := range suite {
		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("the explorer suite is missing %s: %v", name, err)
		}
		wantTests += strings.Count(string(body), "\ntest(")
	}
	// A floor on the floor: the count is derived from the files, so a suite emptied
	// down to one test would agree with itself. This is the number below which the
	// suite has stopped being the gate it was committed as.
	if wantTests < 25 {
		t.Fatalf("counted only %d tests across %v; the suite is larger than that, so either it shrank or the count is wrong", wantTests, tests)
	}

	page := filepath.Join(t.TempDir(), "system-map.html")
	if err := os.WriteFile(page, []byte(renderFixturePage(t)), 0o644); err != nil {
		t.Fatal(err)
	}

	// TAP explicitly: node's default reporter depends on the version and on whether
	// stdout is a terminal, and this test reads the tally to tell a clean run from a
	// run where nothing executed.
	cmd := exec.Command(node, append([]string{"--test", "--test-reporter=tap"}, tests...)...)
	cmd.Dir = dir
	// SYSTEMMAP_PAGE is the whole interface between the two runners: the suite
	// asserts against the inventory embedded in whatever page it is pointed at, so
	// the same files run over this fixture and over the real coordinator map.
	cmd.Env = append(os.Environ(), "SYSTEMMAP_PAGE="+page)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Errorf("the explorer suite failed against the fixture page: %v", err)
		// Only the failing subtests and the tally, or a 200-line TAP dump buries them.
		//
		// `error:` is followed by node's message as an indented YAML block scalar, and
		// the message is the whole point — a bare `not ok 26` says which test broke and
		// nothing about how. So the indented continuation is kept until the block ends,
		// which is at the next line that is neither blank nor more-indented.
		verbatim := false
		for _, line := range strings.Split(string(out), "\n") {
			trimmed := strings.TrimSpace(line)
			indented := strings.HasPrefix(line, "  ") && trimmed != ""
			switch {
			case strings.HasPrefix(trimmed, "not ok"), strings.HasPrefix(trimmed, "# fail"),
				strings.HasPrefix(trimmed, "# pass"):
				verbatim = false
				t.Log(trimmed)
			case strings.HasPrefix(trimmed, "error:"):
				verbatim = true
				t.Log(trimmed)
			case verbatim && indented:
				t.Log(line)
			default:
				verbatim = false
			}
		}
		return
	}
	// A zero exit is not enough on its own: a suite whose tests all vanished exits
	// zero too, and a green skip is exactly the failure this test exists to prevent.
	// The floor is the number of top-level tests the two files declare, so a test
	// that stops being collected is a failure rather than a smaller tally.
	tally := regexp.MustCompile(`(?m)^# pass (\d+)$`).FindStringSubmatch(string(out))
	if tally == nil {
		t.Fatalf("the explorer suite reported no tally:\n%s", out)
	}
	if passed, _ := strconv.Atoi(tally[1]); passed < wantTests {
		t.Errorf("the explorer suite ran %s of its %d tests, so some of it did not run:\n%s", tally[1], wantTests, out)
	}
	if !strings.Contains(string(out), "# fail 0") {
		t.Errorf("the explorer suite reported failures:\n%s", out)
	}
}
