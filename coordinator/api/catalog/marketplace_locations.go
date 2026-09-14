package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// openRouterModelName resolves the feed display name for a model: the catalog
// display name, then the registry display name, then the model ID as a last
// resort.
func openRouterModelName(cm store.SupportedModel, reg store.ModelRegistryEntry, hasReg bool, modelID string) string {
	if cm.DisplayName != "" {
		return cm.DisplayName
	}
	if hasReg && reg.DisplayName != "" {
		return reg.DisplayName
	}
	return modelID
}

// modelDatacenters maps the country codes of providers serving a model into the
// OpenRouter "datacenters" shape, returning nil when none are known so the
// omitempty field is omitted.
func (s *Controller) modelDatacenters(modelID string) []types.OpenRouterDatacenter {
	ccs := s.registry.ModelCountryCodes(modelID)
	if len(ccs) == 0 {
		return nil
	}
	dcs := make([]types.OpenRouterDatacenter, 0, len(ccs))
	for _, cc := range ccs {
		dcs = append(dcs, types.OpenRouterDatacenter{CountryCode: cc})
	}
	return dcs
}
