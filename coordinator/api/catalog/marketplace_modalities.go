package catalog

import (
	"sort"
	"strings"
)

// deriveModalities returns the input and output modalities for a model. Text is
// always present; a vision/multimodal capability adds image input, an audio
// capability adds audio, and a video capability adds video. Embedding models
// report a text->embedding shape.
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
