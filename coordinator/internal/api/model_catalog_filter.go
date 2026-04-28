package api

import (
	"strings"

	"github.com/darkbloom/coordinator/internal/store"
)

// IsRetiredProviderModel returns true for catalog entries that should never be
// provider-selectable, even if a stale row is still present in the store.
func IsRetiredProviderModel(model store.SupportedModel) bool {
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
