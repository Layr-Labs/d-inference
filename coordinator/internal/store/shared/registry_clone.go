package shared

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

func CloneModelRegistryEntry(entry *store.ModelRegistryEntry) store.ModelRegistryEntry {
	if entry == nil {
		return store.ModelRegistryEntry{}
	}
	cp := *entry
	cp.Capabilities = append([]string(nil), entry.Capabilities...)
	cp.RequiredProviderCapabilities = append(
		[]string(nil), entry.RequiredProviderCapabilities...)
	cp.RuntimeParameters = CloneMetadata(entry.RuntimeParameters)
	cp.Metadata = CloneMetadata(entry.Metadata)
	return cp
}
