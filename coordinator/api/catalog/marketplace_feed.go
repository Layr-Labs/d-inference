package catalog

import (
	"net/http"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// ListOpenRouterModels handles GET /v1/models/openrouter.
//
// It emits the pure OpenRouter provider "List Models" schema (no Darkbloom
// metadata block) for the models we want OpenRouter to sell.
//
// The feed is driven by the active CATALOG, not by live provider availability:
// a registered model stays listed even when no provider is momentarily
// online/warm for it. That matches OpenRouter's model, where transient capacity
// is handled by 429s and launch state by the is_ready flag — a provider restart
// must not make the model vanish from the marketplace. Live provider data is
// used only as supplemental signal (datacenters, and excluding a model whose
// providers report a non-text aggregate type).
//
// The feed is the same for every caller and is polled by OpenRouter, so the
// serialized response is served from the read cache for openRouterFeedCacheTTL.
func (s *Controller) ListOpenRouterModels(w http.ResponseWriter, r *http.Request) {
	if body, ok := s.readCacheGet(openRouterFeedCacheKey); ok {
		httpresponse.WriteCachedJSON(w, body)
		return
	}
	generation := s.readCacheGeneration()
	data, err := s.openRouterFeedEntries()
	if err != nil {
		s.logger.Error("openrouter models: failed to list active models", "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to list models"))
		return
	}
	body, err := httpresponse.EncodeCachedJSON(types.OpenRouterModelsResponse{Data: data})
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to encode models"))
		return
	}
	s.readCacheSetIfCurrent(openRouterFeedCacheKey, body, openRouterFeedCacheTTL, generation)
	httpresponse.WriteCachedJSON(w, body)
}

// openRouterFeedCacheTTL bounds staleness of the marketplace feed. The feed is
// catalog-driven (DB), with live providers contributing only datacenters and
// non-text exclusions. Catalog sync invalidates the feed immediately and
// rejects any stale publication from an in-flight pre-sync read.
const openRouterFeedCacheTTL = 5 * time.Second

const openRouterFeedCacheKey = "models:openrouter:v1"

// openRouterFeedEntries assembles the feed: public aliases first, then the
// active concrete catalog models not hidden behind an alias, in stable order.
func (s *Controller) openRouterFeedEntries() ([]types.OpenRouterModel, error) {
	catalogByID, registryByID, err := s.activeCatalogLookups()
	if err != nil {
		return nil, err
	}

	// Provider-reported model types override the catalog's text fallback so
	// known non-text models never enter the OpenRouter provider feed.
	aggTypeByID := s.openRouterAggregateTypeByID()

	// Public aliases get the same treatment as /v1/models: the alias is the
	// purchasable entry and its member builds are hidden, so the marketplace
	// never lists a raw quant build that a migration will later retire (a
	// retired build would otherwise stay listed and black-hole requests).
	aliasEntries, hiddenBuilds, err := s.openRouterAliasEntries(catalogByID, registryByID, aggTypeByID)
	if err != nil {
		return nil, err
	}

	// Stable output order.
	ids := make([]string, 0, len(catalogByID))
	for id := range catalogByID {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	data := make([]types.OpenRouterModel, 0, len(ids)+len(aliasEntries))
	data = append(data, aliasEntries...)
	for _, id := range ids {
		if _, hidden := hiddenBuilds[id]; hidden {
			continue
		}
		entry, ok := s.openRouterEntryForConcrete(id, catalogByID, registryByID, aggTypeByID)
		if !ok {
			continue
		}
		data = append(data, entry)
	}
	return data, nil
}
