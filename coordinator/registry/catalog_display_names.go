package registry

import "strings"

// CatalogDisplayNames returns model ID → human-readable name for every active
// catalog entry that carries one. Names are trimmed; an entry whose name is
// empty or just repeats its ID is left out so callers fall back to their own
// rendering of the raw ID. Builds that share one name (a rollout alias's
// desired and previous builds are both "Gemma 4 26B") are told apart by their
// catalog quantization — "Gemma 4 26B (4bit)" / "Gemma 4 26B (8bit)"; a build
// the quantization cannot separate either is left out rather than labelled
// identically to another. Thread-safe; returns a fresh map.
func (r *Registry) CatalogDisplayNames() map[string]string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	byName := make(map[string][]string, len(r.modelCatalog))
	for id, entry := range r.modelCatalog {
		name := strings.TrimSpace(entry.DisplayName)
		if name == "" || name == id {
			continue
		}
		byName[name] = append(byName[name], id)
	}
	names := make(map[string]string, len(r.modelCatalog))
	for name, ids := range byName {
		if len(ids) == 1 {
			names[ids[0]] = name
			continue
		}
		for id, label := range labelsByQuantization(name, ids, r.modelCatalog) {
			names[id] = label
		}
	}
	return names
}

// labelsByQuantization labels same-named builds "<name> (<quantization>)".
// Only builds whose quantization is non-empty and unique within the group get
// a label; the others are omitted.
func labelsByQuantization(name string, ids []string, catalog map[string]CatalogEntry) map[string]string {
	quantCount := make(map[string]int, len(ids))
	for _, id := range ids {
		if q := strings.TrimSpace(catalog[id].Quantization); q != "" {
			quantCount[q]++
		}
	}
	labels := make(map[string]string, len(ids))
	for _, id := range ids {
		q := strings.TrimSpace(catalog[id].Quantization)
		if q != "" && quantCount[q] == 1 {
			labels[id] = name + " (" + q + ")"
		}
	}
	return labels
}
