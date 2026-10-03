package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// SyncModelCatalog reads active models from the store and updates the
// registry's model catalog. Call this at startup and after admin catalog changes.
func (s *Owner) SyncModelCatalog() { s.Sync() }

// Return whether the committed registry state reached the live routing policy
// and connected providers. Revision callers must retry after either failure.
func (s *Owner) Sync() bool {
	s.modelCatalogSyncMu.Lock()
	defer s.modelCatalogSyncMu.Unlock()
	registryRows, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		s.logger.Error("model registry catalog sync failed", "error", err)
		return false
	}
	entries := make([]registry.CatalogEntry, 0, len(registryRows))
	for _, row := range registryRows {
		if row.ActiveVersion == nil {
			continue
		}
		servingHashes := make([]string, 0, len(row.ServingVersions))
		sizeBytes := row.ActiveVersion.TotalSizeBytes
		for _, v := range row.ServingVersions {
			servingHashes = append(servingHashes, v.AggregateSHA256)
			if v.TotalSizeBytes > sizeBytes {
				sizeBytes = v.TotalSizeBytes
			}
		}
		entries = append(entries, registry.CatalogEntry{
			Revision:            row.ActiveVersion.Version,
			ServingWeightHashes: servingHashes,
			ID:                  row.ID,
			WeightHash:          row.ActiveVersion.AggregateSHA256,
			SizeGB:              float64(sizeBytes) / 1e9,
			MinRAMGB:            row.MinRAMGB,
			RequiredProviderCapabilities: append(
				[]string{}, row.RequiredProviderCapabilities...),
		})
	}
	// Advance the prompt-artifact generation before publishing new routing
	// hashes. Cache planning also carries and compares the aggregate hash, so
	// either side of this handoff is fail-cold under concurrent requests.
	if s.hooks.ReconcilePromptArtifacts != nil {
		if err := s.hooks.ReconcilePromptArtifacts(registryRows); err != nil {
			s.logger.Error("prompt artifact catalog reconcile rejected", "error", err)
		}
	}
	s.registry.SetModelCatalog(entries)
	s.logger.Info("model registry catalog synced to registry", "active_models", len(entries))

	// The catalog has changed even if alias refresh fails. Invalidate its read
	// caches, but do not publish desired state computed from stale aliases.
	defer s.InvalidateCatalogCache()
	if !s.syncModelAliases(registryRows) {
		return false
	}
	// Catalog capability changes can invalidate an in-flight desired-model
	// prefetch even when alias pointers did not change. Re-publish the filtered
	// desired state immediately; newly ineligible providers receive an empty
	// set, which cancels stale reconciliation work.
	return s.FanOutDesiredModels()
}

// syncModelAliases loads standard rollout aliases first, then resolves
// OpenRouter-only aliases through either a standard alias or an active concrete
// catalog model. OpenRouter-only targets route requests but do not participate
// in provider convergence or canonical public naming.
func (s *Owner) syncModelAliases(registryRows []store.ModelRegistryRecord) bool {
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.logger.Error("model alias sync failed", "error", err)
		return false
	}
	resolved := make(map[string]registry.AliasTarget, len(aliases))
	activeConcreteModels := make(map[string]struct{}, len(registryRows))
	for _, row := range registryRows {
		if row.ActiveVersion != nil {
			activeConcreteModels[row.ID] = struct{}{}
		}
	}
	for _, a := range aliases {
		if !a.Active || a.OpenRouterOnly || a.DesiredBuild == "" {
			continue
		}
		resolved[a.AliasID] = registry.AliasTarget{
			Desired:  a.DesiredBuild,
			Previous: a.PreviousBuild,
			Retired:  a.RetiredBuilds,
		}
	}
	for _, a := range aliases {
		if !a.Active || !a.OpenRouterOnly {
			continue
		}
		var target registry.AliasTarget
		var ok bool
		if openRouterAliasUsesConcreteSource(a) {
			if _, ok = activeConcreteModels[a.SourceModel]; ok {
				target = registry.AliasTarget{Desired: a.SourceModel}
			}
		} else {
			target, ok = resolved[a.SourceModel]
		}
		if !ok {
			s.logger.Warn("OpenRouter alias source is unavailable", "alias_id", a.AliasID, "source_model", a.SourceModel)
			continue
		}
		target.OpenRouterOnly = true
		resolved[a.AliasID] = target
	}
	s.registry.SetModelAliases(resolved)
	s.logger.Info("model aliases synced to registry", "active_aliases", len(resolved))
	return true
}

// InvalidateCatalogCache removes all cached model catalog responses so the
// next request picks up any changes made by admin endpoints.
func (s *Owner) InvalidateCatalogCache() {
	if s.readCache == nil {
		return
	}
	for _, typeFilter := range []string{"", "text"} {
		for _, includeAliases := range []bool{false, true} {
			s.readCache.Invalidate(modelCatalogCacheKey(typeFilter, includeAliases))
		}
	}
	// /v1/models entry memo + list bodies (both include_builds values) and the
	// OpenRouter feed are derived from the same catalog; drop them too so an
	// admin alias/registry change is visible on the next request instead of
	// after their 2s/5s TTLs (which remain the bound for out-of-band DB edits).
	for _, includeBuilds := range []bool{false, true} {
		s.readCache.Invalidate(modelEntriesCacheKey(includeBuilds))
		s.readCache.Invalidate(modelListBodyCacheKey(includeBuilds))
	}
	s.readCache.Invalidate(openRouterFeedCacheKey)
	// stats:v1 is deliberately NOT evicted here: the stats refresher recomputes
	// it every minute, and evicting it made every concurrent /v1/stats request
	// rerun the multi-second usage analytics statements.
}
