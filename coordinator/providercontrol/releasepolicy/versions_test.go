package releasepolicy

import (
	"testing"
)

func TestSemverPrereleaseTransitionPrecedence(t *testing.T) {
	if !VersionLess("0.8.16-dev.1", "0.8.16") {
		t.Fatal("prerelease-to-stable must be an approved precedence increase")
	}
	if VersionLess("0.8.16", "0.8.16-dev.1") {
		t.Fatal("stable-to-prerelease must never be treated as a non-downgrade")
	}
}
