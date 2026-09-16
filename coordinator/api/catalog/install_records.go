package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
		"required_provider_capabilities": append(
			[]string{}, rec.RequiredProviderCapabilities...),
		"runtime_parameters": rec.RuntimeParameters,
		"metadata":           rec.Metadata,
		"status":             rec.Status,

		// OpenRouter-shaped fields (mirrors /v1/models) for UI consistency.
		"name":                          supported.DisplayName,
		"hugging_face_id":               huggingFaceIDForModel(supported.ID, rec.Metadata),
		"input_modalities":              inputModalities,
		"output_modalities":             outputModalities,
		"supported_features":            supportedFeaturesFromCapabilities(rec.Capabilities),
		"supported_sampling_parameters": defaultSamplingParameters(),
	}
	if !rec.CreatedAt.IsZero() {
		model["created"] = rec.CreatedAt.Unix()
	}
	if version != nil {
		if version.HuggingFaceArtifact != nil {
			model["hugging_face_artifact"] = version.HuggingFaceArtifact
		}
		model["version"] = version.Version
		model["r2_prefix"] = version.R2Prefix
		model["aggregate_sha256"] = version.AggregateSHA256
		model["total_size_bytes"] = version.TotalSizeBytes
		model["file_count"] = version.FileCount
	}
	return model
}

func catalogAliasesForResponse(models []map[string]any, aliases []store.ModelAlias) []map[string]any {
	catalogIDs := make(map[string]struct{}, len(models))
	for _, model := range models {
		id, _ := model["id"].(string)
		if id != "" {
			catalogIDs[id] = struct{}{}
		}
	}
	response := make([]map[string]any, 0, len(aliases))
	for _, alias := range aliases {
		if !alias.Active || alias.DesiredBuild == "" {
			continue
		}
		displayName := alias.DisplayName
		if displayName == "" {
			displayName = alias.AliasID
		}
		retiredBuilds := alias.RetiredBuilds
		if retiredBuilds == nil {
			retiredBuilds = []string{}
		}
		entry := map[string]any{
			"id":             alias.AliasID,
			"display_name":   displayName,
			"desired_build":  alias.DesiredBuild,
			"retired_builds": retiredBuilds,
		}
		if alias.PreviousBuild != "" {
			entry["previous_build"] = alias.PreviousBuild
		}
		if _, ok := catalogIDs[alias.DesiredBuild]; ok {
			entry["primary_build"] = alias.DesiredBuild
		} else if alias.PreviousBuild != "" {
			if _, ok := catalogIDs[alias.PreviousBuild]; ok {
				entry["primary_build"] = alias.PreviousBuild
			}
		}
		if entry["primary_build"] == nil {
			continue
		}
		response = append(response, entry)
	}
	return response
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
		RequiredProviderCapabilities: append(
			[]string{}, rec.RequiredProviderCapabilities...),
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
