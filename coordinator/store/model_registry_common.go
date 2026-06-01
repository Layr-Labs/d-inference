package store

func manifestFromRecord(rec *ModelRegistryRecord) *ModelManifest {
	if rec == nil || rec.ActiveVersion == nil {
		return nil
	}
	files := make([]ManifestFile, len(rec.Files))
	for i, f := range rec.Files {
		files[i] = ManifestFile{Path: f.Path, SizeBytes: f.SizeBytes, SHA256: f.SHA256, Role: f.Role}
	}
	return &ModelManifest{
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
