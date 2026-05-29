package api

import (
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
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

// openRouterValidQuant is the set of quantization strings OpenRouter accepts.
var openRouterValidQuant = map[string]bool{
	"int4": true, "int8": true, "fp4": true, "fp6": true,
	"fp8": true, "fp16": true, "bf16": true, "fp32": true,
}

// quantAliases maps common MLX / HuggingFace quantization spellings onto the
// OpenRouter-accepted vocabulary.
var quantAliases = map[string]string{
	"4bit": "int4", "4-bit": "int4", "q4": "int4", "int4": "int4",
	"8bit": "int8", "8-bit": "int8", "q8": "int8", "int8": "int8",
	"6bit": "fp6", "6-bit": "fp6",
	"3bit": "int4", "3-bit": "int4", // no int3 in OpenRouter; nearest is int4
	"2bit": "int4", "2-bit": "int4", // no int2 in OpenRouter; nearest is int4
	"fp4": "fp4", "fp6": "fp6", "fp8": "fp8",
	"fp16": "fp16", "bf16": "bf16", "fp32": "fp32",
	"float16": "fp16", "bfloat16": "bf16", "float32": "fp32",
}

// mapQuantizationToOpenRouter normalizes an internal quantization label to the
// OpenRouter vocabulary. Returns "" when no confident mapping exists so the
// caller can omit the field.
func mapQuantizationToOpenRouter(q string) string {
	key := strings.ToLower(strings.TrimSpace(q))
	if key == "" {
		return ""
	}
	if mapped, ok := quantAliases[key]; ok {
		return mapped
	}
	if openRouterValidQuant[key] {
		return key
	}
	// Tolerate trailing descriptors like "4bit-gs64" or "mxfp4".
	for alias, mapped := range quantAliases {
		if strings.Contains(key, alias) {
			return mapped
		}
	}
	return ""
}

// deriveModalities returns the input and output modalities for a model. Text is
// always present; a vision/multimodal capability adds image input. Embedding
// models report a text->embedding shape.
func deriveModalities(modelType string, capabilities []string) (input, output []string) {
	mt := strings.ToLower(strings.TrimSpace(modelType))
	switch mt {
	case "embedding", "embeddings":
		return []string{"text"}, []string{"embedding"}
	}

	input = []string{"text"}
	output = []string{"text"}
	for _, c := range capabilities {
		switch strings.ToLower(strings.TrimSpace(c)) {
		case "vision", "image", "image_input", "multimodal":
			if !contains(input, "image") {
				input = append(input, "image")
			}
		case "audio", "audio_input":
			if !contains(input, "audio") {
				input = append(input, "audio")
			}
		case "file", "pdf":
			if !contains(input, "file") {
				input = append(input, "file")
			}
		}
	}
	return input, output
}

// featureAliases maps internal capability strings onto OpenRouter's feature
// vocabulary.
var featureAliases = map[string]string{
	"tools":              "tools",
	"tool_use":           "tools",
	"tool_calling":       "tools",
	"function_calling":   "tools",
	"functions":          "tools",
	"json":               "json_mode",
	"json_mode":          "json_mode",
	"json_object":        "json_mode",
	"structured_outputs": "structured_outputs",
	"structured_output":  "structured_outputs",
	"json_schema":        "structured_outputs",
	"logprobs":           "logprobs",
	"web_search":         "web_search",
	"search":             "web_search",
	"reasoning":          "reasoning",
	"thinking":           "reasoning",
	"reasoning_parser":   "reasoning",
}

// supportedFeaturesFromCapabilities translates internal capability labels into
// OpenRouter feature names, de-duplicated and sorted for stable output.
func supportedFeaturesFromCapabilities(capabilities []string) []string {
	if len(capabilities) == 0 {
		return nil
	}
	seen := map[string]bool{}
	for _, c := range capabilities {
		if mapped, ok := featureAliases[strings.ToLower(strings.TrimSpace(c))]; ok {
			seen[mapped] = true
		}
	}
	if len(seen) == 0 {
		return nil
	}
	out := make([]string, 0, len(seen))
	for f := range seen {
		out = append(out, f)
	}
	sort.Strings(out)
	return out
}

// defaultSamplingParameters is the set of sampling parameters the Swift
// inference engine actually decodes and applies (see ChatCompletionRequest in
// provider-swift). We deliberately exclude OpenRouter-valid-but-unhonored
// parameters (min_p, top_a, logit_bias) so the feed never advertises sampling
// behavior the provider would silently ignore.
func defaultSamplingParameters() []string {
	return []string{
		"temperature", "top_p", "top_k",
		"frequency_penalty", "presence_penalty", "repetition_penalty",
		"stop", "seed", "max_tokens",
	}
}

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
func (s *Server) resolvePlatformPricing(model string) (inputPerMillion, outputPerMillion int64) {
	if in, out, ok := s.store.GetModelPrice("platform", model); ok {
		return in, out
	}
	return payments.DefaultInputPricePerMillion, payments.DefaultOutputPricePerMillion
}

// activeCatalogLookups builds the two lookups that the model-listing endpoints
// (/v1/models and /v1/models/openrouter) share: the active catalog keyed by
// model ID, and the richer registry entry per model used to populate the
// OpenRouter provider fields. It prefers the DB-backed model registry; when
// that has no rows it falls back to legacy supported_models, which carry no
// registry entry (so registryByID is empty in the fallback case). The error is
// returned so each caller can log it with its own context and emit a 500.
func (s *Server) activeCatalogLookups() (catalogByID map[string]store.SupportedModel, registryByID map[string]store.ModelRegistryEntry, err error) {
	registryRows, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		return nil, nil, err
	}
	catalogByID = make(map[string]store.SupportedModel, len(registryRows))
	registryByID = make(map[string]store.ModelRegistryEntry, len(registryRows))
	if len(registryRows) > 0 {
		for _, row := range registryRows {
			cm := supportedModelFromRegistryRecord(&row)
			if cm.Active {
				catalogByID[cm.ID] = cm
				registryByID[cm.ID] = row.ModelRegistryEntry
			}
		}
		return catalogByID, registryByID, nil
	}
	for _, cm := range s.store.ListSupportedModels() {
		if cm.Active && !IsRetiredProviderModel(cm) {
			catalogByID[cm.ID] = cm
		}
	}
	return catalogByID, registryByID, nil
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
// values when hasReg is false (legacy supported_models rows without a registry
// entry).
func (s *Server) openRouterModelFieldsFor(modelID, rawQuantization string, reg store.ModelRegistryEntry, hasReg bool) openRouterModelFields {
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

// deprecationDateFromMetadata extracts the optional "deprecation_date" string
// from a model's registry metadata, returning "" when it is absent or empty.
func deprecationDateFromMetadata(meta map[string]any) string {
	if dd, ok := meta["deprecation_date"].(string); ok {
		return dd
	}
	return ""
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// isNonTextModelType reports whether a model type is a KNOWN non-text modality
// that must be excluded from the text-only OpenRouter feed. Unknown/empty and
// text-ish types (text, chat, completion) are NOT excluded, so the filter only
// drops models we're confident are not text generation (embeddings, audio,
// image, rerank).
func isNonTextModelType(modelType string) bool {
	switch strings.ToLower(strings.TrimSpace(modelType)) {
	case "embedding", "embeddings", "tts", "stt", "speech", "audio", "image", "vision", "rerank", "reranker":
		return true
	default:
		return false
	}
}

// openRouterIsReady decides whether a model is live on OpenRouter. This is a
// launch/staging flag, NOT a live-capacity signal — transient capacity is
// handled by 429s. Active catalog models default to ready; an operator can
// stage a model by setting metadata "openrouter_is_ready": false (or the alias
// "openrouter_staged": true).
func openRouterIsReady(meta map[string]any) bool {
	if meta == nil {
		return true
	}
	if v, ok := meta["openrouter_is_ready"].(bool); ok {
		return v
	}
	if staged, ok := meta["openrouter_staged"].(bool); ok {
		return !staged
	}
	return true
}

// openRouterSlug returns the OpenRouter marketplace slug for a model: an
// operator override from registry metadata ("openrouter_slug") if present,
// otherwise the model id itself.
//
// OpenRouter's provider spec leaves the slug underspecified and its own example
// sets slug == id, so the id (a globally-unique HuggingFace path) is a safe,
// collision-free default. Operators map a model onto an existing marketplace
// slug (e.g. "qwen/qwen3.5-9b") explicitly via the openrouter_slug metadata
// override / the admin openrouter-slug action.
func openRouterSlug(modelID string, meta map[string]any) string {
	if meta != nil {
		if s, ok := meta["openrouter_slug"].(string); ok && strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	return modelID
}
