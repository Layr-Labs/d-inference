package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	aliaspolicy "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/aliaspolicy"
	modelmeta "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/metadata"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// modelEntryForConcrete builds the consumer catalog representation of one
// provider-advertised concrete model. Callers decide whether the entry is hidden
// behind a standard rollout alias; OpenRouter-only aliases never hide it.
func (s *Owner) modelEntryForConcrete(
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
		HuggingFaceID: modelmeta.HuggingFaceIDForModel(model.ID, registryEntry.Metadata),
		Metadata:      metadata,
	}
	s.openRouterModelFieldsFor(model.ID, model.Quantization, registryEntry, hasRegistryEntry).applyToModelEntry(&entry)

	var capabilities []string
	if hasRegistryEntry {
		capabilities = registryEntry.Capabilities
	}
	entry.InputModalities, entry.OutputModalities = modelmeta.DeriveModalities(model.ModelType, capabilities)
	return entry
}

// modelEntryForCatalogConcrete builds exact-retrieval metadata for an active
// concrete model even when no provider is connected. Live counts remain zero;
// the durable registry supplies identity, limits, pricing, and capabilities.
func (s *Owner) modelEntryForCatalogConcrete(
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

func (s *Owner) openRouterAggregateTypeByID() map[string]string {
	typesByID := make(map[string]string)
	for _, model := range s.registry.ListModels() {
		if model.ModelType != "" {
			typesByID[model.ID] = model.ModelType
		}
	}
	return typesByID
}

// openRouterEntryForConcrete builds the dedicated provider-feed representation
// of one active concrete catalog model. It remains independently listed when an
// OpenRouter-only alias clones it.
func (s *Owner) openRouterEntryForConcrete(
	modelID string,
	catalogByID map[string]store.SupportedModel,
	registryByID map[string]store.ModelRegistryEntry,
	aggregateTypeByID map[string]string,
) (types.OpenRouterModel, bool) {
	catalogModel, ok := catalogByID[modelID]
	if !ok || !aliaspolicy.ConcreteModelEligibleForOpenRouterFeed(modelID, catalogByID, aggregateTypeByID) {
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
	inputModalities, outputModalities := modelmeta.DeriveModalities(modelType, capabilities)
	entry := types.OpenRouterModel{
		ID:                modelID,
		HuggingFaceID:     modelmeta.HuggingFaceIDForModel(modelID, registryEntry.Metadata),
		Name:              openRouterModelName(catalogModel, registryEntry, hasRegistryEntry, modelID),
		InputModalities:   inputModalities,
		OutputModalities:  outputModalities,
		SupportedFeatures: []string{},
		IsReady:           true,
	}
	s.openRouterModelFieldsFor(modelID, registryEntry.Quantization, registryEntry, hasRegistryEntry).applyToFeed(&entry)
	if hasRegistryEntry {
		entry.IsReady = modelmeta.OpenRouterIsReady(registryEntry.Metadata)
		entry.OpenRouter = &types.OpenRouterSlug{Slug: modelmeta.OpenRouterSlug(modelID, registryEntry.Metadata)}
	} else {
		entry.OpenRouter = &types.OpenRouterSlug{Slug: modelmeta.OpenRouterSlug(modelID, nil)}
	}
	entry.Datacenters = s.modelDatacenters(modelID)
	return entry, true
}
