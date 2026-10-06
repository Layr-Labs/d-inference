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

// MissingCacheRoutingAllowlistEntries returns the live artifacts whose models
// the allowlist names only under other tuples. Each is the exact tuple to append.
func (r *Registry) MissingCacheRoutingAllowlistEntries(live []CacheRoutingArtifact) []CacheRoutingArtifact {
	r.mu.RLock()
	allowlist := r.cacheRoutingAllowedArtifacts
	r.mu.RUnlock()
	var missing []CacheRoutingArtifact
	for _, artifact := range live {
		if allowlist.StaleFor(artifact) {
			missing = append(missing, artifact)
		}
	}
	return missing
}
