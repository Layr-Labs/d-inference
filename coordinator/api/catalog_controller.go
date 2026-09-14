package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/catalog"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// catalogController shares one alias lock and the API's existing cache across
// every catalog route and runtime sync. Lazy binding also supports focused API
// fixtures that construct a Server before using catalog operations.
func (s *Server) catalogController() *catalog.Controller {
	s.catalogOnce.Do(func() {
		s.modelCatalog = catalog.New(catalog.Dependencies{
			Store:  func() catalog.Store { return s.store },
			Models: s.registry, Cache: s.readCache, Logger: s.logger,
			AdminKey: func() string { return s.adminKey },
			SelfRouteAccount: func(r *http.Request) (string, bool) {
				policy := s.resolveSelfRoutePolicy(r)
				return policy.OwnerAccountID, policy.Enabled
			},
			SyncCatalog: s.SyncModelCatalog,
		})
	})
	return s.modelCatalog
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
			MinRAMGB:   row.MinRAMGB,
			RequiredProviderCapabilities: append(
				[]string{}, row.RequiredProviderCapabilities...),
		})
	}
	// Advance the prompt-artifact generation before publishing new routing
	// hashes. Cache planning also carries and compares the aggregate hash, so
	// either side of this handoff is fail-cold under concurrent requests.
	if err := s.reconcilePromptArtifacts(registryRows); err != nil {
		s.logger.Error("prompt artifact catalog reconcile rejected", "error", err)
	}
	s.registry.SetModelCatalog(entries)
	s.logger.Info("model registry catalog synced to registry", "active_models", len(entries))

	s.syncModelAliases(registryRows)
	// Catalog capability changes can invalidate an in-flight desired-model
	// prefetch even when alias pointers did not change. Re-publish the filtered
	// desired state immediately; newly ineligible providers receive an empty
	// set, which cancels stale reconciliation work.
	s.fanOutDesiredModels()
	s.invalidateCatalogCache()
}

// syncModelAliases loads standard rollout aliases first, then resolves
// OpenRouter-only aliases through either a standard alias or an active concrete
// catalog model. OpenRouter-only targets route requests but do not participate
// in provider convergence or canonical public naming.
func (s *Server) syncModelAliases(registryRows []store.ModelRegistryRecord) {
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.logger.Error("model alias sync failed", "error", err)
		return
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
		if catalog.AliasUsesConcreteSource(a) {
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
}

// invalidateCatalogCache applies the catalog owner's existing shared-cache invalidation.
func (s *Server) invalidateCatalogCache() { s.catalogController().Invalidate() }
