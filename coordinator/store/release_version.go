package store

import "github.com/eigeninference/d-inference/coordinator/semverutil"
import "errors"

func releaseVersionGreater(a, b string) bool {
	if a == "" {
		return false
	}
	if b == "" {
		_, ok := semverutil.Compare(a, "0.0.0")
		return ok
	}
	return semverutil.Greater(a, b)
}

var ErrReleaseArtifactImmutable = errors.New("release artifact metadata is immutable")

func releaseArtifactEqual(a, b *Release) bool {
	return a != nil && b != nil &&
		a.Version == b.Version && a.Platform == b.Platform &&
		a.Backend == b.Backend && a.BinaryHash == b.BinaryHash &&
		a.BundleHash == b.BundleHash && a.MetallibHash == b.MetallibHash &&
		a.PythonHash == b.PythonHash && a.RuntimeHash == b.RuntimeHash &&
		a.TemplateHashes == b.TemplateHashes && a.URL == b.URL
}
