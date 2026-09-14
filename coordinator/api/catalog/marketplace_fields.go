package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// buildModelPricing resolves the per-token USD pricing block for a model from
// micro-USD-per-million-token rates.
func buildModelPricing(inputPerMillion, outputPerMillion int64) *types.ModelPricing {
	return &types.ModelPricing{
		Prompt:         payments.FormatPerTokenUSD(inputPerMillion),
		Completion:     payments.FormatPerTokenUSD(outputPerMillion),
		Image:          "0",
		Request:        "0",
		InputCacheRead: "0",
	}
}

// resolvePlatformPricing returns the platform-level input/output micro-USD
// per-million rates for a model, falling back to the global defaults when no
// override is configured.
func (s *Controller) resolvePlatformPricing(model string) (inputPerMillion, outputPerMillion int64) {
	if in, out, ok := s.store().GetModelPrice("platform", model); ok {
		return in, out
	}
	return payments.DefaultInputPricePerMillion, payments.DefaultOutputPricePerMillion
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
func (s *Controller) openRouterModelFieldsFor(modelID, rawQuantization string, reg store.ModelRegistryEntry, hasReg bool) openRouterModelFields {
	inPM, outPM := s.resolvePlatformPricing(modelID)
	f := openRouterModelFields{
		Quantization:                mapQuantizationToOpenRouter(rawQuantization),
		Pricing:                     buildModelPricing(inPM, outPM),
		SupportedSamplingParameters: defaultSamplingParameters(),
	}
	if hasReg {
		if !reg.CreatedAt.IsZero() {
			f.Created = reg.CreatedAt.Unix()
		}
		f.Description = reg.Description
		f.ContextLength = reg.MaxContextLength
		f.MaxOutputLength = reg.MaxOutputLength
		f.SupportedFeatures = supportedFeaturesFromCapabilities(reg.Capabilities)
		f.DeprecationDate = deprecationDateFromMetadata(reg.Metadata)
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
