package semverutil

import "github.com/Masterminds/semver/v3"

// Compare returns SemVer precedence and whether both inputs are strict SemVer.
// Build metadata is intentionally ignored by SemVer precedence.
func Compare(a, b string) (int, bool) {
	left, err := semver.StrictNewVersion(a)
	if err != nil {
		return 0, false
	}
	right, err := semver.StrictNewVersion(b)
	if err != nil {
		return 0, false
	}
	return left.Compare(right), true
}

func Greater(a, b string) bool {
	comparison, ok := Compare(a, b)
	return ok && comparison > 0
}
