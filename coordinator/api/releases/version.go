package releases

import (
	"strings"

	"golang.org/x/mod/semver"
)

// SemverGreater returns true when a has higher SemVer precedence than b,
// including the numeric/alphanumeric prerelease identifier rules. Invalid
// non-empty versions sort below valid versions so minimum-version gates fail
// closed.
func SemverGreater(a, b string) bool {
	if a == "" {
		return false
	}
	if b == "" {
		return true
	}
	av := a
	if !strings.HasPrefix(av, "v") {
		av = "v" + av
	}
	bv := b
	if !strings.HasPrefix(bv, "v") {
		bv = "v" + bv
	}
	aValid, bValid := semver.IsValid(av), semver.IsValid(bv)
	switch {
	case aValid && bValid:
		return semver.Compare(av, bv) > 0
	case aValid:
		return true
	default:
		return false
	}
}

// SemverLess returns true if version a is less than version b.
func SemverLess(a, b string) bool {
	return SemverGreater(b, a)
}
