package api

import (
	"regexp"
	"testing"
)

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
