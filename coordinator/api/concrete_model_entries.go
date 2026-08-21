package api

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// modelEntryForConcrete builds the consumer catalog representation of one
// provider-advertised concrete model. Callers decide whether the entry is hidden
// behind a standard rollout alias; OpenRouter-only aliases never hide it.
func (s *Server) modelEntryForConcrete(
	model registry.AggregateModel,
	capacity *registry.ModelCapacity,
	catalogModel store.SupportedModel,
	inCatalog bool,
	registryEntry store.ModelRegistryEntry,
	hasRegistryEntry bool,
) types.ModelEntry {
	metadata := types.ModelMetadata{
		ModelType:         model.ModelType,
		Quantization:      model.Quantization,
		ProviderCount:     model.Providers,
		AttestedProviders: model.AttestedProviders,
		TrustLevel:        string(model.TrustLevel),
	}
	if capacity != nil {
		metadata.RoutableProviders = capacity.RoutableProviders
		metadata.WarmProviders = capacity.WarmProviders
		metadata.CanAccept = capacity.CanAccept
	}
	if model.Attestation != nil {
		metadata.Attestation = &types.ModelAttestation{
			SecureEnclave: model.Attestation.SecureEnclave,
			SIPEnabled:    model.Attestation.SIPEnabled,
			SecureBoot:    model.Attestation.SecureBoot,
		}
	}
	if inCatalog && catalogModel.DisplayName != "" {
		metadata.DisplayName = catalogModel.DisplayName
	}

	entry := types.ModelEntry{
		ID:            model.ID,
		Object:        "model",
		OwnedBy:       "eigeninference",
		Name:          metadata.DisplayName,
		HuggingFaceID: huggingFaceIDForModel(model.ID, registryEntry.Metadata),
		Metadata:      metadata,
	}
	s.openRouterModelFieldsFor(model.ID, model.Quantization, registryEntry, hasRegistryEntry).applyToModelEntry(&entry)

	var capabilities []string
	if hasRegistryEntry {
		capabilities = registryEntry.Capabilities
	}
	entry.InputModalities, entry.OutputModalities = deriveModalities(model.ModelType, capabilities)
	return entry
}

// openRouterEntryForConcrete builds the dedicated provider-feed representation
// of one active concrete catalog model. It remains independently listed when an
// OpenRouter-only alias clones it.
func (s *Server) openRouterEntryForConcrete(
	modelID string,
	catalogByID map[string]store.SupportedModel,
	registryByID map[string]store.ModelRegistryEntry,
	aggregateTypeByID map[string]string,
) (types.OpenRouterModel, bool) {
	catalogModel, ok := catalogByID[modelID]
	if !ok {
		return types.OpenRouterModel{}, false
	}
	modelType := catalogModel.ModelType
	if aggregateType, found := aggregateTypeByID[modelID]; found {
		modelType = aggregateType
	}
	if isNonTextModelType(modelType) {
		return types.OpenRouterModel{}, false
	}

	registryEntry, hasRegistryEntry := registryByID[modelID]
	entry := types.OpenRouterModel{
		ID:                modelID,
		HuggingFaceID:     huggingFaceIDForModel(modelID, registryEntry.Metadata),
		Name:              openRouterModelName(catalogModel, registryEntry, hasRegistryEntry, modelID),
		InputModalities:   []string{"text"},
		OutputModalities:  []string{"text"},
		SupportedFeatures: []string{},
		IsReady:           true,
	}
	s.openRouterModelFieldsFor(modelID, registryEntry.Quantization, registryEntry, hasRegistryEntry).applyToFeed(&entry)
	if hasRegistryEntry {
		entry.IsReady = openRouterIsReady(registryEntry.Metadata)
		entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(modelID, registryEntry.Metadata)}
	} else {
		entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(modelID, nil)}
	}
	entry.Datacenters = s.modelDatacenters(modelID)
	return entry, true
}
