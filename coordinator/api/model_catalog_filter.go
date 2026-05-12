package api

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// IsRetiredProviderModel returns true for catalog entries that should never be
// provider-selectable, even if a stale row is still present in the store.
//
// Two layers of defense:
//
//  1. ModelType filter — the platform only serves text models. Anything tagged
//     "image", "transcription", "audio", "video", "embedding" or similar is
//     refused regardless of name.
//  2. Token filter — historical product names that referred to retired
//     providers (Cohere STT, Flux image generation) are still rejected so a
//     stale row that somehow landed in the DB without a ModelType still gets
//     filtered out.
func IsRetiredProviderModel(model store.SupportedModel) bool {
	if isRetiredModelType(model.ModelType) {
		return true
	}
	fields := []string{
		model.ID,
		model.S3Name,
		model.DisplayName,
	}
	for _, field := range fields {
		if containsRetiredProviderModelToken(field) {
			return true
		}
	}
	return false
}

// allowedModelTypes are the only ModelType values the platform routes. Text is
// the only first-class type today; empty string is treated as text for backward
// compatibility with rows seeded before the column existed.
var allowedModelTypes = map[string]bool{
	"":     true, // legacy: treat as text
	"text": true,
}

func isRetiredModelType(modelType string) bool {
	return !allowedModelTypes[strings.ToLower(strings.TrimSpace(modelType))]
}

func containsRetiredProviderModelToken(value string) bool {
	tokens := strings.FieldsFunc(strings.ToLower(value), func(r rune) bool {
		return (r < 'a' || r > 'z') && (r < '0' || r > '9')
	})
	for _, token := range tokens {
		if token == "cohere" || token == "coherelabs" || token == "flux" || strings.HasPrefix(token, "flux") {
			return true
		}
	}
	return false
}
