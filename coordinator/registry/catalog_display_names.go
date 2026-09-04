package registry

// CatalogDisplayNames returns model ID → human-readable name for every active
// catalog entry that carries one. Entries whose display name is empty or just
// repeats the ID are left out so callers fall back to their own rendering of
// the raw ID rather than echoing it. Thread-safe; returns a fresh map.
func (r *Registry) CatalogDisplayNames() map[string]string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	names := make(map[string]string, len(r.modelCatalog))
	for id, entry := range r.modelCatalog {
		if entry.DisplayName == "" || entry.DisplayName == id {
			continue
		}
		names[id] = entry.DisplayName
	}
	return names
}
