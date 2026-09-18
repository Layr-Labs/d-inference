package api

import "strings"

// sanitizeChipFamilyTag maps untrusted hardware labels to a fixed vocabulary.
// New Apple families need an explicit addition; arbitrary registration strings
// share one fallback across MLX and client-cancellation telemetry.
func sanitizeChipFamilyTag(family string) string {
	family = strings.TrimSpace(family)
	switch family {
	case "", "Unknown":
		return "unknown"
	case "M1", "M1 Pro", "M1 Max", "M1 Ultra",
		"M2", "M2 Pro", "M2 Max", "M2 Ultra",
		"M3", "M3 Pro", "M3 Max", "M3 Ultra",
		"M4", "M4 Pro", "M4 Max", "M4 Ultra",
		"M5", "M5 Pro", "M5 Max", "M5 Ultra":
		return strings.ReplaceAll(family, " ", "_")
	default:
		return "other"
	}
}
