package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"

const (
	cacheArtifactAllowlistEnv = cachepolicy.ArtifactAllowlistEnv
	maxCacheArtifactJSONBytes = cachepolicy.MaxArtifactJSONBytes
	maxCacheArtifacts         = cachepolicy.MaxArtifacts
)

// CacheRoutingArtifact names one verified artifact, not a model family or alias.
// A nil configuration list is unrestricted; an explicitly empty list denies all.
type CacheRoutingArtifact = cachepolicy.Artifact
type cacheArtifactAllowlist = *cachepolicy.ArtifactAllowlist

func readCacheRoutingArtifacts() ([]CacheRoutingArtifact, error) { return cachepolicy.ReadArtifacts() }
func newCacheArtifactAllowlist(artifacts []CacheRoutingArtifact) (cacheArtifactAllowlist, error) {
	return cachepolicy.NewArtifactAllowlist(artifacts)
}
