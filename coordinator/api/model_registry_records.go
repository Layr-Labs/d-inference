package api

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// registryEntryFromRecord copies the mutable model fields out of a stored
// record into a fresh ModelRegistryEntry, so an in-place admin update can
// change one field (e.g. capabilities or runtime parameters) and upsert it
// without dropping the others.
func registryEntryFromRecord(rec *store.ModelRegistryRecord) *store.ModelRegistryEntry {
	return &store.ModelRegistryEntry{
		ID:                rec.ID,
		DisplayName:       rec.DisplayName,
		Family:            rec.Family,
		Architecture:      rec.Architecture,
		Quantization:      rec.Quantization,
		MaxContextLength:  rec.MaxContextLength,
		MaxOutputLength:   rec.MaxOutputLength,
		MinRAMGB:          rec.MinRAMGB,
		Capabilities:      rec.Capabilities,
		Status:            rec.Status,
		Description:       rec.Description,
		RuntimeParameters: rec.RuntimeParameters,
		Metadata:          rec.Metadata,
	}
}

// normalizeCapabilities trims, drops empties, and de-duplicates a capability
// list while preserving first-seen order.
func normalizeCapabilities(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, c := range in {
		c = strings.TrimSpace(c)
		if c == "" || seen[c] {
			continue
		}
		seen[c] = true
		out = append(out, c)
	}
	return out
}
