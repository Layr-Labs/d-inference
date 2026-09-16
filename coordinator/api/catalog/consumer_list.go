package catalog

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// listModelEntries assembles the consumer-facing model entries shared by
// GET /v1/models and GET /v1/models/{id}. includeBuilds also lists the raw
// quant builds hidden behind public aliases (ops/debug).
func (s *Controller) listModelEntries(includeBuilds bool) ([]types.ModelEntry, error) {
	models := s.registry.ListModels()

	capacities := s.registry.ModelCapacitySnapshot()
	capByModel := make(map[string]*registry.ModelCapacity, len(capacities))
	for i := range capacities {
		capByModel[capacities[i].ModelID] = &capacities[i]
	}

	catalogByID, registryByID, err := s.activeCatalogLookups()
	if err != nil {
		return nil, err
	}

	// Build each concrete entry once. OpenRouter-only aliases may clone these
	// entries, while standard aliases independently decide which builds to hide.
	concreteEntries := make(map[string]types.ModelEntry, len(models))
	concreteOrder := make([]string, 0, len(models))
	for _, model := range models {
		catalogModel, inCatalog := catalogByID[model.ID]
		if len(catalogByID) > 0 && !inCatalog {
			continue
		}
		registryEntry, hasRegistryEntry := registryByID[model.ID]
		concreteEntries[model.ID] = s.modelEntryForConcrete(
			model,
			capByModel[model.ID],
			catalogModel,
			inCatalog,
			registryEntry,
			hasRegistryEntry,
		)
		concreteOrder = append(concreteOrder, model.ID)
	}

	aliasEntries, hiddenBuilds, err := s.aliasModelEntries(capByModel, catalogByID, registryByID)
	if err != nil {
		return nil, err
	}
	data := make([]types.ModelEntry, 0, len(concreteEntries)+len(aliasEntries))
	data = append(data, aliasEntries...)
	for _, modelID := range concreteOrder {
		if _, hidden := hiddenBuilds[modelID]; hidden && !includeBuilds {
			continue
		}
		data = append(data, concreteEntries[modelID])
	}
	return data, nil
}

func (s *Controller) ListModels(w http.ResponseWriter, r *http.Request) {
	// The owned-model view follows the request's resolved route mode, exactly
	// like inference: a SelfRouteOnly key always, or any key sending
	// X-Darkbloom-Route: self — so a client that lists (or validates) models
	// with the same header it will infer with discovers the same ids the
	// inference path accepts. Header-less requests on ordinary keys see the
	// public catalog, matching their public routing. (prefer falls back to the
	// paid fleet, so it keeps the public view.)
	if policy := s.selfRoute(r); policy.enabled {
		entries := s.OwnedModelEntries(policy.ownerAccountID, r.URL.Query().Get("include_builds") == "1")
		httpresponse.WriteJSON(w, http.StatusOK, types.ModelListResponse{
			Object: "list",
			Data:   filterEntriesByKeyAllowList(entries, requestcontext.APIKey(r.Context())),
		})
		return
	}

	// Pass ?include_builds=1 (ops/debug) to also list the raw quant builds.
	// The public catalog is the same for every caller (no per-key filtering
	// applies to it), so the whole response is served from the read cache.
	body, err := s.cachedModelListBody(r.URL.Query().Get("include_builds") == "1")
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to list models"))
		return
	}
	httpresponse.WriteCachedJSON(w, body)
}

// filterEntriesByKeyAllowList restricts a self-route model view to the key's
// allow-list when one is set. Owned live models are private inventory (unlike
// the public catalog): a restricted key handed out for one local model must
// not enumerate — or retrieve metadata for — the account's other machine
// models, mirroring what keyModelAllowed would let it actually use. An empty
// allow-list means the key may use (and therefore see) everything.
func filterEntriesByKeyAllowList(entries []types.ModelEntry, k *store.APIKey) []types.ModelEntry {
	if k == nil || len(k.AllowedModels) == 0 {
		return entries
	}
	allowed := make(map[string]struct{}, len(k.AllowedModels))
	for _, m := range k.AllowedModels {
		allowed[m] = struct{}{}
	}
	filtered := make([]types.ModelEntry, 0, len(entries))
	for _, e := range entries {
		if _, ok := allowed[e.ID]; ok {
			filtered = append(filtered, e)
		}
	}
	return filtered
}
