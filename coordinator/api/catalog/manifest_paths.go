package catalog

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

func containsTraversal(value string) bool {
	return strings.Contains(value, "..")
}

func validRegistryIdentifier(value string, allowSlash bool) bool {
	if value == "" || strings.HasPrefix(value, "/") || containsTraversal(value) {
		return false
	}
	for _, r := range value {
		if r >= '0' && r <= '9' || r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r == '.' || r == '_' || r == '-' {
			continue
		}
		if allowSlash && r == '/' {
			continue
		}
		return false
	}
	return true
}

func ModelR2Prefix(modelID, version string) string {
	return "v2/" + readableModelSlug(modelID) + "/" + version
}

func readableModelSlug(modelID string) string {
	var b strings.Builder
	b.Grow(len(modelID) + 14)
	for _, r := range modelID {
		switch {
		case r >= '0' && r <= '9', r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r == '.', r == '_', r == '-':
			b.WriteRune(r)
		case r == '/':
			b.WriteByte('-')
		default:
			b.WriteByte('-')
		}
	}
	slug := strings.Trim(b.String(), "-")
	if slug == "" {
		slug = "model"
	}
	sum := sha256.Sum256([]byte(modelID))
	return slug + "--" + hex.EncodeToString(sum[:])[:12]
}
