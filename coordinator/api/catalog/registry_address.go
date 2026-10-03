package catalog

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"strings"
)

func registryCDNBaseURL() string {
	base := strings.TrimRight(strings.TrimSpace(os.Getenv("MODEL_REGISTRY_CDN_BASE_URL")), "/")
	if base == "" {
		return defaultModelRegistryCDNBaseURL
	}
	return base
}

func modelR2Prefix(modelID, version string) string {
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

func validModelStatus(status string) bool {
	switch status {
	case "beta", "active", "deprecated", "retired":
		return true
	default:
		return false
	}
}
