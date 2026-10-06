package registry

import "strings"

func (e CatalogEntry) acceptsWeightHash(hash string) bool {
	if hash == "" {
		return false
	}
	if strings.EqualFold(hash, e.WeightHash) {
		return true
	}
	for _, approved := range e.ServingWeightHashes {
		if strings.EqualFold(hash, approved) {
			return true
		}
	}
	return false
}

// CatalogAcceptsWeightHash keeps approved old revisions valid through downloads,
// draining, reconnects and coordinator restarts. Never admits an unpromoted hash.
func (r *Registry) CatalogAcceptsWeightHash(modelID, hash string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.modelCatalog[modelID].acceptsWeightHash(hash)
}
