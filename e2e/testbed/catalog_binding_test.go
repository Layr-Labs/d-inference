package testbed

import (
	"encoding/json"
	"os"
	"slices"
	"testing"

	"github.com/stretchr/testify/require"
)

// CPU-only proof using the actual canonical input and actual seedCatalog path.
func TestCanonicalCatalogSeedingPreservesConsumedPolicyAndManifest(t *testing.T) {
	path := os.Getenv("DARKBLOOM_CANONICAL_CATALOG_INPUT")
	if path == "" {
		t.Skip("explicit canonical input fixture required")
	}
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	var input struct {
		Catalog []CatalogModel `json:"catalog"`
	}
	require.NoError(t, json.Unmarshal(raw, &input))
	require.NotEmpty(t, input.Catalog)
	st := NewMemoryStore()
	require.NoError(t, seedCatalog(st, input.Catalog, nil))
	for _, model := range input.Catalog {
		record, err := st.GetModelRegistryRecord(model.Entry.ID)
		require.NoError(t, err)
		require.NotNil(t, record)
		// Storage fills fixture timestamps; it does not mutate the bound input.
		actual := record.ModelRegistryEntry
		// The existing store clone represents an empty required-capability slice
		// as nil; the ordered requirements themselves must remain identical.
		require.True(t, slices.Equal(model.Entry.RequiredProviderCapabilities, actual.RequiredProviderCapabilities))
		actual.RequiredProviderCapabilities = model.Entry.RequiredProviderCapabilities
		actual.CreatedAt = model.Entry.CreatedAt
		actual.UpdatedAt = model.Entry.UpdatedAt
		require.Equal(t, model.Entry, actual)
		require.NotNil(t, record.ActiveVersion)
		require.Equal(t, model.Manifest.ModelID, record.ActiveVersion.ModelID)
		require.Equal(t, model.Manifest.Version, record.ActiveVersion.Version)
		require.Equal(t, model.Manifest.AggregateSHA256, record.ActiveVersion.AggregateSHA256)
		require.Equal(t, model.Manifest.R2Prefix, record.ActiveVersion.R2Prefix)
		require.Equal(t, model.Manifest.TotalSizeBytes, record.ActiveVersion.TotalSizeBytes)
		require.Equal(t, model.Manifest.FileCount, record.ActiveVersion.FileCount)
		require.Len(t, record.Files, len(model.Manifest.Files))
		byPath := map[string]string{}
		for _, file := range record.Files {
			byPath[file.Path] = file.SHA256
		}
		for _, file := range model.Manifest.Files {
			require.Equal(t, file.SHA256, byPath[file.Path])
		}
	}
}
