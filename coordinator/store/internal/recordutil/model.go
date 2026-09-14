package recordutil

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func CloneModelAlias(a *contracts.ModelAlias) contracts.ModelAlias {
	cp := *a
	// RetiredBuilds is the only reference-typed field; copy it so callers can't
	// mutate stored state through the returned value.
	if a.RetiredBuilds != nil {
		cp.RetiredBuilds = append([]string(nil), a.RetiredBuilds...)
	}
	return cp
}

func CloneModelRegistryEntry(entry *contracts.ModelRegistryEntry) contracts.ModelRegistryEntry {
	if entry == nil {
		return contracts.ModelRegistryEntry{}
	}
	cp := *entry
	cp.Capabilities = append([]string(nil), entry.Capabilities...)
	cp.RequiredProviderCapabilities = append(
		[]string(nil), entry.RequiredProviderCapabilities...)
	cp.RuntimeParameters = CloneMetadata(entry.RuntimeParameters)
	cp.Metadata = CloneMetadata(entry.Metadata)
	return cp
}

func CloneModelVersion(version *contracts.ModelVersion) contracts.ModelVersion {
	if version == nil {
		return contracts.ModelVersion{}
	}
	cp := *version
	cp.PromotedAt = CloneTimePtr(version.PromotedAt)
	cp.HuggingFaceArtifact = CloneHuggingFaceArtifact(version.HuggingFaceArtifact)
	cp.Metadata = CloneMetadata(version.Metadata)
	return cp
}

func ManifestFromRecord(rec *contracts.ModelRegistryRecord) *contracts.ModelManifest {
	if rec == nil || rec.ActiveVersion == nil {
		return nil
	}
	files := make([]contracts.ManifestFile, len(rec.Files))
	for i, f := range rec.Files {
		files[i] = contracts.ManifestFile{Path: f.Path, SizeBytes: f.SizeBytes, SHA256: f.SHA256, Role: f.Role}
	}
	return &contracts.ModelManifest{
		SchemaVersion:   1,
		ModelID:         rec.ID,
		Version:         rec.ActiveVersion.Version,
		R2Prefix:        rec.ActiveVersion.R2Prefix,
		AggregateSHA256: rec.ActiveVersion.AggregateSHA256,
		TotalSizeBytes:  rec.ActiveVersion.TotalSizeBytes,
		FileCount:       rec.ActiveVersion.FileCount,
		Files:           files,
		CreatedAt:       rec.ActiveVersion.UploadedAt,
	}
}
