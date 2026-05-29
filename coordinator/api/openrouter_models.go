package api

import (
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
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

// defaultSamplingParameters is the full set of sampling parameters the
// coordinator forwards to providers. Because the raw request body is passed
// through to the inference engine untouched, every OpenRouter-valid sampling
// parameter is supported.
func defaultSamplingParameters() []string {
	return []string{
		"temperature", "top_p", "top_k", "min_p", "top_a",
		"frequency_penalty", "presence_penalty", "repetition_penalty",
		"stop", "seed", "max_tokens", "logit_bias",
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

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// isTextModelType reports whether a catalog model type should appear in the
// text-only OpenRouter feed. Empty/text/chat/completion count as text;
// embedding/tts/image/audio do not.
func isTextModelType(modelType string) bool {
	switch strings.ToLower(strings.TrimSpace(modelType)) {
	case "", "text", "chat", "completion":
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
// otherwise a derived "darkbloom/<slug>" default from the model id.
func openRouterSlug(modelID string, meta map[string]any) string {
	if meta != nil {
		if s, ok := meta["openrouter_slug"].(string); ok && strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	tail := modelID
	if i := strings.LastIndex(modelID, "/"); i >= 0 && i+1 < len(modelID) {
		tail = modelID[i+1:]
	}
	slug := slugify(tail)
	if slug == "" {
		slug = slugify(modelID)
	}
	return "darkbloom/" + slug
}

// slugify lowercases and replaces any run of non-alphanumeric characters with a
// single hyphen, trimming leading/trailing hyphens.
func slugify(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	prevHyphen := false
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			prevHyphen = false
		} else if !prevHyphen {
			b.WriteByte('-')
			prevHyphen = true
		}
	}
	return strings.Trim(b.String(), "-")
}
