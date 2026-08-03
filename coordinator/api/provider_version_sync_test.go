package api

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// AGENTS.md: "`LatestProviderVersion` in `coordinator/api/server.go` is only
// the no-release-row fallback for the version *display* path and must stay in
// sync with `ProviderCore.version`."
//
// Nothing enforced that until now, and the two drifted apart silently through
// several releases. The failure is quiet by construction: production reads the
// latest version from the releases table, so a stale fallback only shows up on
// dev and in-memory coordinators, where it makes them advertise a floor the
// Swift binary does not match.
//
// This is the same shape as the three-way telemetry allowlist guard — a
// cross-language constant with no compiler between the two sides, so the test
// IS the linkage.
func TestLatestProviderVersionMatchesProviderCore(t *testing.T) {
	const rel = "../../provider-swift/Sources/ProviderCore/ProviderCore.swift"

	src, err := os.ReadFile(rel)
	if err != nil {
		t.Fatalf("cannot read %s: %v", filepath.Clean(rel), err)
	}

	// `public static let version = "0.8.0"` — anchored on the declaration so a
	// version string mentioned in a comment cannot satisfy it.
	re := regexp.MustCompile(`(?m)^\s*public static let version = "([^"]+)"`)
	m := re.FindSubmatch(src)
	if m == nil {
		t.Fatalf("could not find `public static let version` in %s: the "+
			"declaration moved or was renamed, so this guard is no longer "+
			"reading what it thinks it is", filepath.Clean(rel))
	}
	swift := string(m[1])

	if LatestProviderVersion != swift {
		t.Fatalf("version drift: coordinator LatestProviderVersion = %q but "+
			"ProviderCore.version = %q.\n\n"+
			"These must move together. The coordinator value is the fallback "+
			"served when no release row exists, so a mismatch makes dev and "+
			"in-memory coordinators advertise a floor the provider binary does "+
			"not satisfy — and production hides it, because production reads "+
			"the releases table instead.", LatestProviderVersion, swift)
	}
}

// A version that is not parseable as a release tag breaks the installer and
// `darkbloom update`, both of which compare against it.
func TestLatestProviderVersionIsWellFormed(t *testing.T) {
	re := regexp.MustCompile(`^\d+\.\d+\.\d+$`)
	if !re.MatchString(LatestProviderVersion) {
		t.Fatalf("LatestProviderVersion = %q, want a bare MAJOR.MINOR.PATCH "+
			"with no leading v and no suffix: the installer and "+
			"`darkbloom update` compare against it directly",
			LatestProviderVersion)
	}
}
