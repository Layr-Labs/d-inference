package api

// Three-way telemetry field-allowlist parity guard.
//
// The allowlist is mirrored in three places:
//
//	Go   (authoritative, server-side filter) telemetryFieldAllowlist, this package
//	Swift (client-side pre-filter)           provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift
//	TS   (console-ui client-side set)        console-ui/src/lib/telemetry-types.ts
//
// Drift is silent in the dangerous direction: add a field to Go alone and the
// Swift client filter strips it before transmission, so the field simply never
// exists. Nothing errors, no test fails, and the gap is invisible until someone
// goes looking for a metric that was never emitted. The pre-existing guards all
// miss this — coordinator/protocol/telemetry_symmetry_test.go pins event shape,
// TelemetrySymmetryTests.swift pins the kind set, and
// TestTelemetryFieldAllowlistHasKnownKeys only checks Go-side existence of seven
// hardcoded keys.
//
// This test parses the two client mirrors out of their source files at test time
// and asserts set equality against the Go map. The "parser" is deliberately dumb:
// it locates the set literal by its opening line, then pulls double-quoted string
// members out of it. It is not a Swift or TypeScript parser and must never grow
// into one — if either literal stops being a flat list of quoted strings, rewrite
// this guard rather than teaching it syntax.

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

const (
	mirrorSwift = "Swift"
	mirrorTS    = "TypeScript"

	swiftAllowlistPath = "provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift"
	tsAllowlistPath    = "console-ui/src/lib/telemetry-types.ts"

	swiftAllowlistOpen  = "private static let allowed: Set<String> = ["
	swiftAllowlistClose = "]"

	tsAllowlistOpen  = "export const TELEMETRY_ALLOWED_FIELDS = new Set<string>(["
	tsAllowlistClose = "]);"
)

// ---------------------------------------------------------------------------
// Known, documented, pre-existing gaps
// ---------------------------------------------------------------------------

// telemetryMirrorGap is one (key, mirror) pair that is currently allowed to
// disagree with the Go allowlist.
type telemetryMirrorGap struct {
	key    string
	mirror string
	why    string
}

// telemetryKnownMirrorGaps enumerates the realised drift that already ships, as
// documented in docs/reference/telemetry-schema.md:110 ("Discrepancies").
//
// These are client-side completeness gaps, not wire incompatibilities: the Go
// server accepts all five keys, but the named client never sends them because
// its own filter drops them first. Fixing the drift is a separate change with
// its own review — this list exists so that the guard passes on the current tree
// while still catching any NEW divergence.
//
// Each entry must be justified. To retire one, delete it here and add the key to
// the named mirror in the same change; TestTelemetryAllowlistKnownGapsAreStillReal
// fails on stale entries so this list cannot rot.
var telemetryKnownMirrorGaps = []telemetryMirrorGap{
	// 1. network_reachable — emitted only by coordinator-side connectivity
	//    bookkeeping today; neither client populates it.
	{key: "network_reachable", mirror: mirrorSwift, why: "docs/reference/telemetry-schema.md:110 — Go only"},
	{key: "network_reachable", mirror: mirrorTS, why: "docs/reference/telemetry-schema.md:110 — Go only"},

	// 2. coordinator_url — same connectivity group as network_reachable.
	{key: "coordinator_url", mirror: mirrorSwift, why: "docs/reference/telemetry-schema.md:110 — Go only"},
	{key: "coordinator_url", mirror: mirrorTS, why: "docs/reference/telemetry-schema.md:110 — Go only"},

	// 3. url — browser context; the TS mirror has it, Swift has no use for it.
	{key: "url", mirror: mirrorSwift, why: "docs/reference/telemetry-schema.md:110 — Go, TS (console-UI context)"},

	// 4. user_agent — browser context; TS only, as above.
	{key: "user_agent", mirror: mirrorSwift, why: "docs/reference/telemetry-schema.md:110 — Go, TS (console-UI context)"},

	// 5. route — console-UI SPA route; TS only, as above.
	{key: "route", mirror: mirrorSwift, why: "docs/reference/telemetry-schema.md:110 — Go, TS (console-UI context)"},
}

func telemetryGapIndex() map[string]map[string]string {
	idx := make(map[string]map[string]string, len(telemetryKnownMirrorGaps))
	for _, g := range telemetryKnownMirrorGaps {
		if idx[g.key] == nil {
			idx[g.key] = map[string]string{}
		}
		idx[g.key][g.mirror] = g.why
	}
	return idx
}

// ---------------------------------------------------------------------------
// Diff
// ---------------------------------------------------------------------------

// telemetryParityFinding is one actionable disagreement between mirrors.
type telemetryParityFinding struct {
	key    string
	mirror string // the mirror that is out of step
	detail string
}

func (f telemetryParityFinding) String() string {
	return "  " + f.key + ": " + f.detail
}

// diffTelemetryMirrors compares each client mirror against the authoritative Go
// allowlist in both directions and returns every disagreement not covered by
// telemetryKnownMirrorGaps.
//
// Missing-from-client is the silent-drift direction (field never transmitted).
// Extra-in-client is the wasted-bandwidth direction (field sent, dropped by the
// server) and is never excused.
func diffTelemetryMirrors(goSet map[string]struct{}, mirrors map[string]map[string]struct{}, excused map[string]map[string]string) []telemetryParityFinding {
	var out []telemetryParityFinding

	names := make([]string, 0, len(mirrors))
	for name := range mirrors {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		client := mirrors[name]

		for _, key := range telemetrySortedKeys(goSet) {
			if _, ok := client[key]; ok {
				continue
			}
			if _, ok := excused[key][name]; ok {
				continue
			}
			out = append(out, telemetryParityFinding{
				key:    key,
				mirror: name,
				detail: "present in Go (telemetryFieldAllowlist) but MISSING from the " + name +
					" mirror — the " + name + " client filter will strip it, so the field will never be transmitted",
			})
		}

		for _, key := range telemetrySortedKeys(client) {
			if _, ok := goSet[key]; ok {
				continue
			}
			out = append(out, telemetryParityFinding{
				key:    key,
				mirror: name,
				detail: "present in the " + name + " mirror but MISSING from Go (telemetryFieldAllowlist) — " +
					"the server will drop it on ingest",
			})
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestTelemetryAllowlistThreeWayParity(t *testing.T) {
	root := telemetryRepoRoot(t)

	swift := loadTelemetryMirror(t, filepath.Join(root, swiftAllowlistPath), swiftAllowlistOpen, swiftAllowlistClose, mirrorSwift)
	ts := loadTelemetryMirror(t, filepath.Join(root, tsAllowlistPath), tsAllowlistOpen, tsAllowlistClose, mirrorTS)

	findings := diffTelemetryMirrors(
		telemetryFieldAllowlist,
		map[string]map[string]struct{}{mirrorSwift: swift, mirrorTS: ts},
		telemetryGapIndex(),
	)
	if len(findings) == 0 {
		return
	}

	var b strings.Builder
	b.WriteString("telemetry field allowlist has drifted between mirrors:\n")
	for _, f := range findings {
		b.WriteString(f.String())
		b.WriteString("\n")
	}
	b.WriteString("\nAll three mirrors must agree:\n")
	b.WriteString("  Go   coordinator/api/telemetry_handlers.go        telemetryFieldAllowlist\n")
	b.WriteString("  " + mirrorSwift + " " + swiftAllowlistPath + "  TelemetryFieldFilter.allowed\n")
	b.WriteString("  " + mirrorTS + " " + tsAllowlistPath + "        TELEMETRY_ALLOWED_FIELDS\n")
	b.WriteString("Add the key to every mirror. If the omission is deliberate, add it to\n")
	b.WriteString("telemetryKnownMirrorGaps in this file with a justification.\n")
	t.Fatal(b.String())
}

// TestTelemetryAllowlistKnownGapsAreStillReal keeps the exception list honest: an
// entry that no longer describes real drift must be deleted, not left to silently
// excuse a future regression on the same key.
func TestTelemetryAllowlistKnownGapsAreStillReal(t *testing.T) {
	root := telemetryRepoRoot(t)

	mirrors := map[string]map[string]struct{}{
		mirrorSwift: loadTelemetryMirror(t, filepath.Join(root, swiftAllowlistPath), swiftAllowlistOpen, swiftAllowlistClose, mirrorSwift),
		mirrorTS:    loadTelemetryMirror(t, filepath.Join(root, tsAllowlistPath), tsAllowlistOpen, tsAllowlistClose, mirrorTS),
	}

	for _, g := range telemetryKnownMirrorGaps {
		client, ok := mirrors[g.mirror]
		if !ok {
			t.Errorf("known gap %q names unknown mirror %q", g.key, g.mirror)
			continue
		}
		if _, inGo := telemetryFieldAllowlist[g.key]; !inGo {
			t.Errorf("stale exception: %q is no longer in the Go allowlist; remove the %s entry from telemetryKnownMirrorGaps",
				g.key, g.mirror)
			continue
		}
		if _, present := client[g.key]; present {
			t.Errorf("stale exception: %q is now present in the %s mirror; remove that entry from telemetryKnownMirrorGaps "+
				"(and update docs/reference/telemetry-schema.md:110)", g.key, g.mirror)
		}
	}
}

// TestTelemetryAllowlistDiffDetectsNewDrift exercises the comparison itself on
// synthetic sets, so the guard's teeth are proven independently of whatever the
// real mirrors happen to contain today.
func TestTelemetryAllowlistDiffDetectsNewDrift(t *testing.T) {
	goSet := map[string]struct{}{"shared": {}, "go_only": {}, "excused": {}}
	mirrors := map[string]map[string]struct{}{
		mirrorSwift: {"shared": {}, "excused_is_absent_here": {}},
		mirrorTS:    {"shared": {}, "go_only": {}},
	}
	excused := map[string]map[string]string{
		"excused": {mirrorSwift: "test", mirrorTS: "test"},
	}

	findings := diffTelemetryMirrors(goSet, mirrors, excused)

	want := map[string]string{
		mirrorSwift + "/go_only":                "missing from client",
		mirrorSwift + "/excused_is_absent_here": "missing from Go",
	}
	got := map[string]bool{}
	for _, f := range findings {
		got[f.mirror+"/"+f.key] = true
	}
	for k := range want {
		if !got[k] {
			t.Errorf("diff missed %s; findings: %v", k, findings)
		}
	}
	if got[mirrorSwift+"/excused"] || got[mirrorTS+"/excused"] {
		t.Errorf("diff reported an excused gap; findings: %v", findings)
	}
	if got[mirrorTS+"/go_only"] {
		t.Errorf("diff reported a key the TS mirror does have; findings: %v", findings)
	}
}

// ---------------------------------------------------------------------------
// Source-file scraping
// ---------------------------------------------------------------------------

// telemetryRepoRoot walks up from the test's working directory (coordinator/api)
// looking for the module root. Skips rather than fails when it cannot find one,
// so the guard is inert in a partial checkout instead of spuriously red.
func telemetryRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Skipf("cannot determine working directory: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Skip("repo root (go.mod) not found above the test working directory; " +
				"skipping telemetry allowlist parity check")
		}
		dir = parent
	}
}

// loadTelemetryMirror reads one client allowlist. A missing file skips the test
// (partial checkout — provider-swift and console-ui are not needed to build the
// coordinator); a present-but-unparseable file fails, because that means the
// literal changed shape and the guard has quietly stopped guarding.
func loadTelemetryMirror(t *testing.T, path, openMark, closeMark, name string) map[string]struct{} {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			t.Skipf("%s mirror not present at %s; skipping telemetry allowlist parity check", name, path)
		}
		t.Fatalf("read %s mirror %s: %v", name, path, err)
	}
	set, err := parseQuotedSetLiteral(string(raw), openMark, closeMark)
	if err != nil {
		t.Fatalf("parse %s allowlist in %s: %v\n"+
			"The set literal changed shape. Update the markers in "+
			"telemetry_allowlist_parity_test.go — do not delete this guard.", name, path, err)
	}
	return set
}

// parseQuotedSetLiteral extracts the double-quoted members of a flat set literal.
//
// It scans for the line containing openMark, then consumes lines until one whose
// trimmed text equals closeMark, collecting every double-quoted token. Line
// comments are stripped first so commentary cannot contribute phantom members.
func parseQuotedSetLiteral(src, openMark, closeMark string) (map[string]struct{}, error) {
	lines := strings.Split(src, "\n")

	start := -1
	for i, line := range lines {
		if strings.Contains(line, openMark) {
			start = i
			break
		}
	}
	if start < 0 {
		return nil, fmt.Errorf("opening marker %q not found", openMark)
	}

	out := make(map[string]struct{})
	// Tolerate members on the opening line itself (neither mirror does this
	// today, but the literals get reflowed by formatters).
	head := lines[start][strings.Index(lines[start], openMark)+len(openMark):]
	collectQuotedTokens(stripTrailingLineComment(head), out)

	for _, line := range lines[start+1:] {
		body := stripTrailingLineComment(line)
		if strings.TrimSpace(body) == closeMark {
			if len(out) == 0 {
				return nil, fmt.Errorf("set literal after %q is empty", openMark)
			}
			return out, nil
		}
		collectQuotedTokens(body, out)
	}
	return nil, fmt.Errorf("closing marker %q not found after %q", closeMark, openMark)
}

// stripTrailingLineComment removes a trailing // comment, ignoring // that
// appears inside a double-quoted string.
func stripTrailingLineComment(line string) string {
	inQuote, escaped := false, false
	for i := range len(line) {
		c := line[i]
		switch {
		case escaped:
			escaped = false
		case c == '\\' && inQuote:
			escaped = true
		case c == '"':
			inQuote = !inQuote
		case c == '/' && !inQuote && i+1 < len(line) && line[i+1] == '/':
			return line[:i]
		}
	}
	return line
}

// collectQuotedTokens adds every double-quoted token in s to out.
func collectQuotedTokens(s string, out map[string]struct{}) {
	for {
		i := strings.IndexByte(s, '"')
		if i < 0 {
			return
		}
		j := strings.IndexByte(s[i+1:], '"')
		if j < 0 {
			return
		}
		if key := s[i+1 : i+1+j]; key != "" {
			out[key] = struct{}{}
		}
		s = s[i+j+2:]
	}
}

func telemetrySortedKeys(m map[string]struct{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
