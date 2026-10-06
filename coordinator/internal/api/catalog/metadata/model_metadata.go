package metadata

import (
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
)

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
func MapQuantizationToOpenRouter(q string) string {
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
// always present; a vision/multimodal capability adds image input, an audio
// capability adds audio, and a video capability adds video. Embedding models
// report a text->embedding shape.
func DeriveModalities(modelType string, capabilities []string) (input, output []string) {
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
		case "video", "video_input":
			if !contains(input, "video") {
				input = append(input, "video")
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
func SupportedFeaturesFromCapabilities(capabilities []string) []string {
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
func DefaultSamplingParameters() []string {
	return []string{
		"temperature", "top_p", "top_k",
		"frequency_penalty", "presence_penalty", "repetition_penalty",
		"stop", "seed", "max_tokens",
	}
}

// buildModelPricing renders the settlement rates as the OpenRouter per-token
// USD pricing block. input_cache_read is the rate cached prompt tokens
// actually settle at (payments.Rates.CacheRead) — the same figure
// handleCompleteAt bills — so OpenRouter's cost for a request with
// prompt_tokens_details.cached_tokens equals the debit. This is OpenRouter's
// legacy flat provider format, which has no cache-write key; caching is
// provider-initiated and writes are unbilled, so none is needed (the current
// v2 format would express this rate as an implicit cached_prompt SKU).
func BuildModelPricing(rates payments.Rates) *types.ModelPricing {
	return &types.ModelPricing{
		Prompt:         payments.FormatPerTokenUSD(rates.Input),
		Completion:     payments.FormatPerTokenUSD(rates.Output),
		Image:          "0",
		Request:        "0",
		InputCacheRead: payments.FormatPerTokenUSD(rates.CacheRead),
	}
}

// deprecationDateFromMetadata extracts the optional "deprecation_date" string
// from a model's registry metadata, returning "" when it is absent or empty.
func DeprecationDateFromMetadata(meta map[string]any) string {
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
func IsNonTextModelType(modelType string) bool {
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
func OpenRouterIsReady(meta map[string]any) bool {
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

const HuggingFaceIDMetadataKey = "hugging_face_id"

// huggingFaceIDForModel returns the exact Hugging Face repository OpenRouter
// should inspect. Most concrete model ids are already Hugging Face paths; an
// explicit metadata value supports internal routing ids without conflating the
// two identities.
func HuggingFaceIDForModel(modelID string, meta map[string]any) string {
	if id, ok := meta[HuggingFaceIDMetadataKey].(string); ok {
		if id = strings.TrimSpace(id); id != "" {
			return id
		}
	}
	return modelID
}

// openRouterSlug returns the OpenRouter marketplace slug for a model: an
// operator override from registry metadata ("openrouter_slug") if present,
// otherwise the model id itself.
//
// OpenRouter's provider spec leaves the slug underspecified and its own example
// sets slug == id, so the globally unique model id is a safe, collision-free
// default. Operators map a model onto an existing marketplace
// slug (e.g. "qwen/qwen3.5-9b") explicitly via the openrouter_slug metadata
// override / the admin openrouter-slug action.
func OpenRouterSlug(modelID string, meta map[string]any) string {
	if meta != nil {
		if s, ok := meta["openrouter_slug"].(string); ok && strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	return modelID
}
