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

// modelEntryForCatalogConcrete builds exact-retrieval metadata for an active
// concrete model even when no provider is connected. Live counts remain zero;
// the durable registry supplies identity, limits, pricing, and capabilities.
func (s *Server) modelEntryForCatalogConcrete(
	modelID string,
	catalogByID map[string]store.SupportedModel,
	registryByID map[string]store.ModelRegistryEntry,
) (types.ModelEntry, bool) {
	catalogModel, ok := catalogByID[modelID]
	if !ok {
		return types.ModelEntry{}, false
	}
	registryEntry, hasRegistryEntry := registryByID[modelID]
	entry := s.modelEntryForConcrete(
		registry.AggregateModel{
			ID:           modelID,
			ModelType:    catalogModel.ModelType,
			Quantization: registryEntry.Quantization,
		},
		nil,
		catalogModel,
		true,
		registryEntry,
		hasRegistryEntry,
	)
	return entry, true
}

func (s *Server) openRouterAggregateTypeByID() map[string]string {
	typesByID := make(map[string]string)
	for _, model := range s.registry.ListModels() {
		if model.ModelType != "" {
			typesByID[model.ID] = model.ModelType
		}
	}
	return typesByID
}

func concreteModelEligibleForOpenRouterFeed(
	modelID string,
	catalogByID map[string]store.SupportedModel,
	aggregateTypeByID map[string]string,
) bool {
	catalogModel, ok := catalogByID[modelID]
	if !ok {
		return false
	}
	modelType := catalogModel.ModelType
	if aggregateType, found := aggregateTypeByID[modelID]; found {
		modelType = aggregateType
	}
	return !isNonTextModelType(modelType)
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
	if !ok || !concreteModelEligibleForOpenRouterFeed(modelID, catalogByID, aggregateTypeByID) {
		return types.OpenRouterModel{}, false
	}

	registryEntry, hasRegistryEntry := registryByID[modelID]
	modelType := catalogModel.ModelType
	if aggregateType, found := aggregateTypeByID[modelID]; found {
		modelType = aggregateType
	}
	var capabilities []string
	if hasRegistryEntry {
		capabilities = registryEntry.Capabilities
	}
	inputModalities, outputModalities := deriveModalities(modelType, capabilities)
	entry := types.OpenRouterModel{
		ID:                modelID,
		HuggingFaceID:     huggingFaceIDForModel(modelID, registryEntry.Metadata),
		Name:              openRouterModelName(catalogModel, registryEntry, hasRegistryEntry, modelID),
		InputModalities:   inputModalities,
		OutputModalities:  outputModalities,
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
