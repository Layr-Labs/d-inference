package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

// activeCatalogLookups builds the two lookups that the model-listing endpoints
// (/v1/models and /v1/models/openrouter) share: the active catalog keyed by
// model ID, and the richer registry entry per model used to populate the
// OpenRouter provider fields, both sourced from the DB-backed model registry.
// The error is returned so each caller can log it with its own context and emit
// a 500.
func (s *Controller) activeCatalogLookups() (catalogByID map[string]store.SupportedModel, registryByID map[string]store.ModelRegistryEntry, err error) {
	registryRows, err := s.store().ListActiveModelRegistryWithError()
	if err != nil {
		return nil, nil, err
	}
	catalogByID = make(map[string]store.SupportedModel, len(registryRows))
	registryByID = make(map[string]store.ModelRegistryEntry, len(registryRows))
	for _, row := range registryRows {
		cm := supportedModelFromRegistryRecord(&row)
		if cm.Active {
			catalogByID[cm.ID] = cm
			registryByID[cm.ID] = row.ModelRegistryEntry
		}
	}
	return catalogByID, registryByID, nil
}
