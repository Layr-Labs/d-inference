package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	metadata "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/metadata"
	registration "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/registration"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// This file contains the mapping helpers that translate Darkbloom's internal
// model catalog metadata into the OpenRouter provider /v1/models schema.
//
// OpenRouter constrains several fields to fixed value sets:
//   - quantization: int4, int8, fp4, fp6, fp8, fp16, bf16, fp32
//   - sampling params: temperature, top_p, top_k, min_p, top_a,
//     frequency_penalty, presence_penalty, repetition_penalty, stop, seed,
//     max_tokens, logit_bias
//   - features: tools, json_mode, structured_outputs, logprobs, web_search,
//     reasoning
//
// We map best-effort and omit values we cannot confidently translate rather
// than emitting invalid ones.

// resolvePlatformPricing returns the platform-level settlement rates for a
// model, falling back to the global defaults when no price row is configured.
func (s *Owner) resolvePlatformPricing(model string) payments.Rates {
	return payments.RatesFor(s.store.GetModelPrice("platform", model))
}

// activeCatalogLookups builds the two lookups that the model-listing endpoints
// (/v1/models and /v1/models/openrouter) share: the active catalog keyed by
// model ID, and the richer registry entry per model used to populate the
// OpenRouter provider fields, both sourced from the DB-backed model registry.
// The error is returned so each caller can log it with its own context and emit
// a 500.
func (s *Owner) activeCatalogLookups() (catalogByID map[string]store.SupportedModel, registryByID map[string]store.ModelRegistryEntry, err error) {
	return registration.ActiveCatalogLookups(s.store)
}

// openRouterModelFields holds the OpenRouter-schema values that both the
// /v1/models enrichment and the dedicated /v1/models/openrouter feed derive
// identically from a model and its (optional) registry entry. Centralizing the
// derivation keeps the two endpoints in lockstep; each maps these onto its own
// response struct via the applyTo* helpers below.
type openRouterModelFields struct {
	Quantization                string
	Pricing                     *types.ModelPricing
	SupportedSamplingParameters []string
	Created                     int64
	Description                 string
	ContextLength               int
	MaxOutputLength             int
	SupportedFeatures           []string
	DeprecationDate             string
}

// openRouterModelFieldsFor derives the shared OpenRouter fields for a model.
// Pricing and sampling parameters come from the platform price table; the
// quantization is mapped from rawQuantization (the aggregate's value for
// /v1/models, or the registry entry's value for the catalog-driven feed); the
// remaining fields come from the registry entry and are left at their zero
// values when hasReg is false (a model present in routing but without a
// registry record).
func (s *Owner) openRouterModelFieldsFor(modelID, rawQuantization string, reg store.ModelRegistryEntry, hasReg bool) openRouterModelFields {
	f := openRouterModelFields{
		Quantization:                metadata.MapQuantizationToOpenRouter(rawQuantization),
		Pricing:                     metadata.BuildModelPricing(s.resolvePlatformPricing(modelID)),
		SupportedSamplingParameters: metadata.DefaultSamplingParameters(),
	}
	if hasReg {
		if !reg.CreatedAt.IsZero() {
			f.Created = reg.CreatedAt.Unix()
		}
		f.Description = reg.Description
		f.ContextLength = reg.MaxContextLength
		f.MaxOutputLength = reg.MaxOutputLength
		f.SupportedFeatures = metadata.SupportedFeaturesFromCapabilities(reg.Capabilities)
		f.DeprecationDate = metadata.DeprecationDateFromMetadata(reg.Metadata)
	}
	return f
}

// applyToModelEntry copies the shared OpenRouter fields onto a /v1/models
// ModelEntry (which also carries the Darkbloom metadata block). Modalities are
// set by the caller, which derives them from the model's capabilities.
func (f openRouterModelFields) applyToModelEntry(entry *types.ModelEntry) {
	entry.Quantization = f.Quantization
	entry.Pricing = f.Pricing
	entry.SupportedSamplingParameters = f.SupportedSamplingParameters
	entry.Created = f.Created
	entry.Description = f.Description
	entry.ContextLength = f.ContextLength
	entry.MaxOutputLength = f.MaxOutputLength
	entry.SupportedFeatures = f.SupportedFeatures
	entry.DeprecationDate = f.DeprecationDate
}

// applyToFeed copies the shared OpenRouter fields onto a pure feed entry. The
// feed emits required fields without omitempty, so an empty feature set is left
// as the caller's pre-initialized []string{} (never nilled out), and modalities
// / is_ready / slug remain the caller's responsibility.
func (f openRouterModelFields) applyToFeed(entry *types.OpenRouterModel) {
	entry.Quantization = f.Quantization
	entry.Pricing = *f.Pricing
	entry.SupportedSamplingParameters = f.SupportedSamplingParameters
	entry.Created = f.Created
	entry.Description = f.Description
	entry.ContextLength = f.ContextLength
	entry.MaxOutputLength = f.MaxOutputLength
	if len(f.SupportedFeatures) > 0 {
		entry.SupportedFeatures = f.SupportedFeatures
	}
	entry.DeprecationDate = f.DeprecationDate
}
