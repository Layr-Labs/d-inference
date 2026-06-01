package api

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const defaultModelRegistryCDNBaseURL = "https://models.darkbloom.ai"

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

func (s *Server) writeModelRegistryStoreError(w http.ResponseWriter, operation string, err error) {
	if isModelRegistryNotFound(err) {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
		return
	}
	s.logger.Error("model registry store error", "operation", operation, "error", err)
	writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "model registry store error"))
}

func isModelRegistryNotFound(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(strings.ToLower(err.Error()), "not found")
}

func catalogModelFromRegistryRecord(rec *store.ModelRegistryRecord) map[string]any {
	supported := supportedModelFromRegistryRecord(rec)
	version := rec.ActiveVersion
	inputModalities, outputModalities := deriveModalities(supported.ModelType, rec.Capabilities)
	model := map[string]any{
		"id":                 supported.ID,
		"s3_name":            supported.S3Name,
		"display_name":       supported.DisplayName,
		"model_type":         supported.ModelType,
		"size_gb":            supported.SizeGB,
		"architecture":       supported.Architecture,
		"description":        supported.Description,
		"min_ram_gb":         supported.MinRAMGB,
		"active":             supported.Active,
		"weight_hash":        supported.WeightHash,
		"family":             rec.Family,
		"quantization":       rec.Quantization,
		"max_context_length": rec.MaxContextLength,
		"max_output_length":  rec.MaxOutputLength,
		"capabilities":       rec.Capabilities,
		"runtime_parameters": rec.RuntimeParameters,
		"metadata":           rec.Metadata,
		"status":             rec.Status,

		// OpenRouter-shaped fields (mirrors /v1/models) for UI consistency.
		"name":                          supported.DisplayName,
		"hugging_face_id":               supported.ID,
		"input_modalities":              inputModalities,
		"output_modalities":             outputModalities,
		"supported_features":            supportedFeaturesFromCapabilities(rec.Capabilities),
		"supported_sampling_parameters": defaultSamplingParameters(),
	}
	if !rec.CreatedAt.IsZero() {
		model["created"] = rec.CreatedAt.Unix()
	}
	if version != nil {
		model["version"] = version.Version
		model["r2_prefix"] = version.R2Prefix
		model["aggregate_sha256"] = version.AggregateSHA256
		model["total_size_bytes"] = version.TotalSizeBytes
		model["file_count"] = version.FileCount
	}
	return model
}

func supportedModelFromRegistryRecord(rec *store.ModelRegistryRecord) store.SupportedModel {
	active := rec.Status == "active" || rec.Status == "beta"
	model := store.SupportedModel{
		ID:           rec.ID,
		DisplayName:  rec.DisplayName,
		ModelType:    "text",
		Architecture: rec.Architecture,
		Description:  rec.Description,
		MinRAMGB:     rec.MinRAMGB,
		Active:       active,
	}
	if rec.ActiveVersion != nil {
		model.S3Name = rec.ActiveVersion.R2Prefix
		model.SizeGB = float64(rec.ActiveVersion.TotalSizeBytes) / 1e9
		model.WeightHash = rec.ActiveVersion.AggregateSHA256
		model.Active = active && rec.ActiveVersion.Status == "ready"
	} else {
		model.Active = false
	}
	return model
}

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
