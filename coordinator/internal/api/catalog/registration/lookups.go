package registration

import "github.com/eigeninference/d-inference/coordinator/store"

// ActiveCatalogLookups derives catalog and registry views from the same inventory read.
func ActiveCatalogLookups(st interface {
	ListActiveModelRegistryWithError() ([]store.ModelRegistryRecord, error)
}) (map[string]store.SupportedModel, map[string]store.ModelRegistryEntry, error) {
	rows, err := st.ListActiveModelRegistryWithError()
	if err != nil {
		return nil, nil, err
	}
	catalog := make(map[string]store.SupportedModel, len(rows))
	registry := make(map[string]store.ModelRegistryEntry, len(rows))
	for _, row := range rows {
		model := SupportedModelFromRegistryRecord(&row)
		if model.Active {
			catalog[model.ID] = model
			registry[model.ID] = row.ModelRegistryEntry
		}
	}
	return catalog, registry, nil
}
