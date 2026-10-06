// Package dedicatedpolicy matches configured dedicated model families.
package dedicatedpolicy

import (
	"iter"
	"strings"
)

// PatternFor returns the first normalized pattern contained in the model ID.
// An empty pattern list disables dedicated-model routing.
func PatternFor(patterns []string, model string) (string, bool) {
	if len(patterns) == 0 {
		return "", false
	}
	m := strings.ToLower(model)
	for _, p := range patterns {
		if strings.Contains(m, p) {
			return p, true
		}
	}
	return "", false
}

// Dedicated requires at least one catalog-allowed model and rejects any model
// outside the family. The caller supplies only catalog-allowed model IDs.
func Dedicated(pattern string, models iter.Seq[string]) bool {
	advertised := 0
	for model := range models {
		advertised++
		if !strings.Contains(strings.ToLower(model), pattern) {
			return false
		}
	}
	return advertised > 0
}
