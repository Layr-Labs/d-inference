package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// LatestProviderVersion is the fallback version returned only when no
// release has been registered in the store (e.g. in-memory dev setups).
// Production reads the latest version from the releases table.
//
// 0.5.0 is the Swift cutover release: pure Swift CLI, no Python runtime,
// no vllm-mlx subprocess. Providers reporting backend == "mlx-swift" skip
// the python/runtime hash checks via registry.BackendUsesSwiftRuntime.
var LatestProviderVersion = "0.5.0"

// latestReleasedVersion returns the highest active release version from
// the store, falling back to the hardcoded LatestProviderVersion when
// no release record exists.
func (s *Server) latestReleasedVersion() string {
	if release := s.store.GetLatestRelease("macos-arm64"); release != nil {
		return release.Version
	}
	return LatestProviderVersion
}

// SyncModelCatalog reads active models from the store and updates the
// registry's model catalog. Call this at startup and after admin catalog changes.
func (s *Server) SyncModelCatalog() {
	registryRows, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		s.logger.Error("model registry catalog sync failed", "error", err)
		return
	}
	entries := make([]registry.CatalogEntry, 0, len(registryRows))
	for _, row := range registryRows {
		if row.ActiveVersion == nil {
			continue
		}
		entries = append(entries, registry.CatalogEntry{
			ID:         row.ID,
			WeightHash: row.ActiveVersion.AggregateSHA256,
			SizeGB:     float64(row.ActiveVersion.TotalSizeBytes) / 1e9,
		})
	}
	s.registry.SetModelCatalog(entries)
	s.logger.Info("model registry catalog synced to registry", "active_models", len(entries))
	s.invalidateCatalogCache()
}

// invalidateCatalogCache removes all cached model catalog responses so the
// next request picks up any changes made by admin endpoints.
func (s *Server) invalidateCatalogCache() {
	if s.readCache == nil {
		return
	}
	s.readCache.Invalidate("models:catalog")
	s.readCache.Invalidate("models:catalog:text")
}
