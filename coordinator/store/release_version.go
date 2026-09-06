package store

import (
	"fmt"
	"strings"

	releaseSemver "github.com/eigeninference/d-inference/coordinator/semver"
)

func validateReleaseIdentity(release *Release) error {
	if release == nil {
		return fmt.Errorf("release is required")
	}
	if !releaseSemver.IsValid(release.Version) {
		return fmt.Errorf("version must be canonical SemVer 2")
	}
	if release.Platform == "" {
		return fmt.Errorf("platform is required")
	}
	return nil
}

func compareReleaseVersions(a, b string) int {
	aVersion, aError := releaseSemver.Parse(a)
	bVersion, bError := releaseSemver.Parse(b)
	switch {
	case aError == nil && bError != nil:
		return 1
	case aError != nil && bError == nil:
		return -1
	case aError != nil:
		return strings.Compare(a, b)
	default:
		return aVersion.Compare(bVersion)
	}
}
