package catalog

import (
	"errors"
	"net/http"
	"strings"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	registration "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/registration"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// registryEntryFromRecord copies the mutable model fields out of a stored
// record into a fresh ModelRegistryEntry, so an in-place admin update can
// change one field (e.g. capabilities or runtime parameters) and upsert it
// without dropping the others.
func registryEntryFromRecord(rec *store.ModelRegistryRecord) *store.ModelRegistryEntry {
	return &store.ModelRegistryEntry{
		ID:               rec.ID,
		DisplayName:      rec.DisplayName,
		Family:           rec.Family,
		Architecture:     rec.Architecture,
		Quantization:     rec.Quantization,
		MaxContextLength: rec.MaxContextLength,
		MaxOutputLength:  rec.MaxOutputLength,
		MinRAMGB:         rec.MinRAMGB,
		Capabilities:     rec.Capabilities,
		RequiredProviderCapabilities: append(
			[]string{}, rec.RequiredProviderCapabilities...),
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

func (s *Owner) writeModelRegistryStoreError(w http.ResponseWriter, operation string, err error) {
	if errors.Is(err, store.ErrModelVersionRetired) {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}
	if registration.IsModelRegistryNotFound(err) {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", err.Error()))
		return
	}
	s.logger.Error("model registry store error", "operation", operation, "error", err)
	httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "model registry store error"))
}
