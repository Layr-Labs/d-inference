package testbed

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// CatalogModel is a complete test-only registry row and immutable manifest.
// Suites seed it into their isolated store before providers connect.
type CatalogModel struct {
	Entry    store.ModelRegistryEntry
	Manifest store.ModelManifest
}

func seedCatalog(st store.Store, models []CatalogModel, aliases []store.ModelAlias) error {
	for _, model := range models {
		manifest := model.Manifest
		if model.Entry.ID == "" || manifest.ModelID != model.Entry.ID {
			return fmt.Errorf("catalog model id mismatch: entry=%q manifest=%q", model.Entry.ID, manifest.ModelID)
		}
		if manifest.Version == "" || manifest.AggregateSHA256 == "" || manifest.FileCount != len(manifest.Files) {
			return fmt.Errorf("catalog model %q has an incomplete manifest", model.Entry.ID)
		}
		files := make([]store.ModelVersionFile, 0, len(manifest.Files))
		for _, file := range manifest.Files {
			files = append(files, store.ModelVersionFile{
				Path: file.Path, SizeBytes: file.SizeBytes, SHA256: file.SHA256, Role: file.Role,
			})
		}
		entry := model.Entry
		if err := st.SetModelVersion(&entry, &store.ModelVersion{
			ModelID: manifest.ModelID, Version: manifest.Version, R2Prefix: manifest.R2Prefix,
			AggregateSHA256: manifest.AggregateSHA256, TotalSizeBytes: manifest.TotalSizeBytes,
			FileCount: manifest.FileCount, Status: "ready",
		}, files); err != nil {
			return fmt.Errorf("seed catalog model %q: %w", entry.ID, err)
		}
		if err := st.PromoteModelVersion(entry.ID, manifest.Version); err != nil {
			return fmt.Errorf("promote catalog model %q: %w", entry.ID, err)
		}
	}
	for i := range aliases {
		alias := aliases[i]
		if err := st.UpsertModelAlias(&alias); err != nil {
			return fmt.Errorf("seed model alias %q: %w", alias.AliasID, err)
		}
	}
	return nil
}
