package api

// Consumer-facing model catalog endpoints: GET /v1/models and
// GET /v1/models/{id}. Public aliases are surfaced as the consumer-facing model
// names; the concrete quant builds behind them are hidden by default. Capacity
// fields come from the live registry snapshot.

import (
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func hideAliasBuild(hidden map[string]struct{}, catalogByID map[string]store.SupportedModel, buildID string) {
	if buildID == "" {
		return
	}
	if _, inCatalog := catalogByID[buildID]; inCatalog {
		hidden[buildID] = struct{}{}
	}
}

// aliasModelEntries builds the consumer-facing /v1/models entries for active
// standard aliases and their OpenRouter-only clones, and returns the set of
// underlying build ids standard aliases cover. Standard aliases hide every
// desired, previous, and retired build from the default listing. OpenRouter-only
// aliases clone either a standard alias or a concrete entry without hiding or
// changing the canonical name of their source.
func (s *Server) aliasModelEntries(
	capByModel map[string]*registry.ModelCapacity,
	catalogByID map[string]store.SupportedModel,
	registryByID map[string]store.ModelRegistryEntry,
	concreteEntries map[string]types.ModelEntry,
) ([]types.ModelEntry, map[string]struct{}) {
	hidden := make(map[string]struct{})
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.logger.Error("model registry: failed to list aliases", "error", err)
		return nil, hidden
	}

	entries := make([]types.ModelEntry, 0, len(aliases))
	standardEntries := make(map[string]types.ModelEntry, len(aliases))
	for _, a := range aliases {
		if !a.Active || a.OpenRouterOnly || a.DesiredBuild == "" {
			continue
		}
		// A consumer must only ever see the alias, never a concrete build behind
		// it. Hide EVERY build this alias references — desired, previous, AND the
		// retired lineage — from the standalone listing, even if the alias itself
		// isn't advertisable right now. (Capacity below aggregates only the
		// routable desired/previous members; retired builds are hide-only.)
		hideAliasBuild(hidden, catalogByID, a.DesiredBuild)
		hideAliasBuild(hidden, catalogByID, a.PreviousBuild)
		for _, b := range a.RetiredBuilds {
			hideAliasBuild(hidden, catalogByID, b)
		}
		// Primary build = the desired build when it's in the catalog, else the
		// previous build (so the alias keeps a real entry while the desired build
		// is mid-registration). An alias whose builds are all out of catalog
		// resolves to nothing and must not be advertised (it would 503).
		members := make([]string, 0, 2)
		desiredInCatalog := false
		if _, ok := catalogByID[a.DesiredBuild]; ok {
			members = append(members, a.DesiredBuild)
			desiredInCatalog = true
		}
		previousInCatalog := false
		if a.PreviousBuild != "" {
			if _, ok := catalogByID[a.PreviousBuild]; ok {
				members = append(members, a.PreviousBuild)
				previousInCatalog = true
			}
		}
		var primary string
		switch {
		case desiredInCatalog:
			primary = a.DesiredBuild
		case previousInCatalog:
			primary = a.PreviousBuild
		default:
			// No in-catalog build backs this alias — don't advertise it.
			continue
		}

		routable, warm := 0, 0
		canAccept := false
		for _, b := range members {
			if cap, ok := capByModel[b]; ok {
				routable += cap.RoutableProviders
				warm += cap.WarmProviders
				canAccept = canAccept || cap.CanAccept
			}
		}

		cm := catalogByID[primary]
		reg, hasReg := registryByID[primary]
		displayName := a.DisplayName
		if displayName == "" {
			displayName = cm.DisplayName
		}
		metadata := types.ModelMetadata{
			ModelType:         cm.ModelType,
			Quantization:      "", // an alias spans quants; omit the per-build quant
			DisplayName:       displayName,
			RoutableProviders: routable,
			WarmProviders:     warm,
			CanAccept:         canAccept,
		}
		entry := types.ModelEntry{
			ID:            a.AliasID,
			Object:        "model",
			OwnedBy:       "eigeninference",
			Name:          displayName,
			HuggingFaceID: huggingFaceIDForModel(primary, reg.Metadata),
			Metadata:      metadata,
		}
		// Pricing / context / features come from the primary build's registry
		// entry. Quantization is intentionally left blank on the alias.
		primaryQuant := ""
		if hasReg {
			primaryQuant = reg.Quantization
		}
		s.openRouterModelFieldsFor(primary, primaryQuant, reg, hasReg).applyToModelEntry(&entry)
		entry.Quantization = ""
		var caps []string
		if hasReg {
			caps = reg.Capabilities
		}
		entry.InputModalities, entry.OutputModalities = deriveModalities(cm.ModelType, caps)
		entries = append(entries, entry)
		standardEntries[a.AliasID] = entry
	}

	// OpenRouter-only aliases are valid inference names but never own or hide
	// their source. Clone a standard rollout alias when present; otherwise clone
	// an independently-listed concrete catalog model.
	for _, a := range aliases {
		if !a.Active || !a.OpenRouterOnly {
			continue
		}
		source, ok := standardEntries[a.SourceModel]
		if !ok {
			source, ok = concreteEntries[a.SourceModel]
		}
		if !ok || a.OpenRouterSlug == "" || a.HuggingFaceID == "" {
			s.logger.Warn("model registry: OpenRouter alias source or identities unavailable", "alias_id", a.AliasID, "source_model", a.SourceModel)
			continue
		}
		clone := source
		clone.ID = a.AliasID
		clone.HuggingFaceID = a.HuggingFaceID
		entries = append(entries, clone)
	}
	return entries, hidden
}

// listModelEntries assembles the consumer-facing model entries shared by
// GET /v1/models and GET /v1/models/{id}. includeBuilds also lists the raw
// quant builds hidden behind public aliases (ops/debug).
func (s *Server) listModelEntries(includeBuilds bool) ([]types.ModelEntry, error) {
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

	aliasEntries, hiddenBuilds := s.aliasModelEntries(
		capByModel,
		catalogByID,
		registryByID,
		concreteEntries,
	)
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

func (s *Server) handleListModels(w http.ResponseWriter, r *http.Request) {
	// The owned-model view follows the request's resolved route mode, exactly
	// like inference: a SelfRouteOnly key always, or any key sending
	// X-Darkbloom-Route: self — so a client that lists (or validates) models
	// with the same header it will infer with discovers the same ids the
	// inference path accepts. Header-less requests on ordinary keys see the
	// public catalog, matching their public routing. (prefer falls back to the
	// paid fleet, so it keeps the public view.)
	if policy := s.resolveSelfRoutePolicy(r); policy.enabled {
		entries := s.selfRouteModelEntries(policy.ownerAccountID, r.URL.Query().Get("include_builds") == "1")
		writeJSON(w, http.StatusOK, types.ModelListResponse{
			Object: "list",
			Data:   filterEntriesByKeyAllowList(entries, apiKeyFromContext(r.Context())),
		})
		return
	}

	// Pass ?include_builds=1 (ops/debug) to also list the raw quant builds.
	data, err := s.listModelEntries(r.URL.Query().Get("include_builds") == "1")
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list models"))
		return
	}

	writeJSON(w, http.StatusOK, types.ModelListResponse{
		Object: "list",
		Data:   data,
	})
}

// selfRouteModelEntries assembles the /v1/models view for a self-route-only
// key: the account's own live machine models instead of the public catalog.
// Owned catalog builds behind an active public alias are presented under the
// alias id — the documented, consumer-facing name that self-route inference
// resolves too — with the concrete quant builds hidden, mirroring the public
// listing. includeHidden re-exposes those covered builds so retrieve-by-exact-
// id keeps working (parity with the public GET /v1/models/{id}, which serves
// hidden builds via listModelEntries(true)).
func (s *Server) selfRouteModelEntries(accountID string, includeHidden bool) []types.ModelEntry {
	models := s.registry.OwnedModels(accountID)
	byID := make(map[string]registry.AggregateModel, len(models))
	for _, m := range models {
		byID[m.ID] = m
	}

	aliases, err := s.store.ListModelAliases()
	if err != nil {
		// Degrade to the raw build listing rather than hiding the owner's
		// models outright.
		s.logger.Error("model registry: failed to list aliases for self-route models", "error", err)
		aliases = nil
	}

	covered := make(map[string]struct{})
	data := make([]types.ModelEntry, 0, len(models))
	for _, a := range aliases {
		if !a.Active || a.DesiredBuild == "" {
			continue
		}
		// Owned members: the alias's live builds this account's machines
		// actually serve. Retired builds stay raw — the alias would not
		// resolve to them for inference.
		members := make([]registry.AggregateModel, 0, 2)
		for _, b := range []string{a.DesiredBuild, a.PreviousBuild} {
			if m, ok := byID[b]; b != "" && ok {
				members = append(members, m)
			}
		}
		if len(members) == 0 {
			continue
		}
		// Primary member (desired-first order above) carries the metadata;
		// provider counts aggregate across members, mirroring the public
		// alias entry's capacity roll-up.
		agg := members[0]
		for _, m := range members[1:] {
			agg.Providers += m.Providers
			agg.AttestedProviders += m.AttestedProviders
		}
		agg.ID = a.AliasID
		// An alias spans quants; omit the per-build quant like the public list.
		agg.Quantization = ""
		entry := ownedModelEntry(agg)
		if a.DisplayName != "" {
			entry.Name = a.DisplayName
			entry.Metadata.DisplayName = a.DisplayName
		}
		data = append(data, entry)
		for _, m := range members {
			covered[m.ID] = struct{}{}
		}
	}

	for _, m := range models {
		if _, hidden := covered[m.ID]; hidden && !includeHidden {
			continue
		}
		data = append(data, ownedModelEntry(m))
	}
	return data
}

// ownedModelEntry converts one owned-model aggregate into the consumer-facing
// entry shape shared by the self-route list and retrieve endpoints.
func ownedModelEntry(m registry.AggregateModel) types.ModelEntry {
	metadata := types.ModelMetadata{
		ModelType:         m.ModelType,
		Quantization:      m.Quantization,
		ProviderCount:     m.Providers,
		AttestedProviders: m.AttestedProviders,
		TrustLevel:        string(m.TrustLevel),
		RoutableProviders: m.Providers,
		CanAccept:         m.Providers > 0,
	}
	if m.Attestation != nil {
		metadata.Attestation = &types.ModelAttestation{
			SecureEnclave: m.Attestation.SecureEnclave,
			SIPEnabled:    m.Attestation.SIPEnabled,
			SecureBoot:    m.Attestation.SecureBoot,
		}
	}
	return types.ModelEntry{
		ID:            m.ID,
		Object:        "model",
		OwnedBy:       "self",
		Name:          m.ID,
		HuggingFaceID: m.ID,
		Quantization:  m.Quantization,
		Metadata:      metadata,
	}
}

// handleGetModel handles GET /v1/models/{id...} — the OpenAI "retrieve model"
// endpoint. Model IDs may contain slashes (HuggingFace paths), hence the
// wildcard path segment. Hidden quant builds are retrievable by their exact
// id, matching the behavior of requesting one for inference.
func (s *Server) handleGetModel(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	// Self-route requests retrieve from their owned live models (mirrors
	// handleListModels, including the header-based opt-in): list and retrieve
	// must agree, or an OpenAI client that validates a model id via
	// retrieve-model can never use a listed local model.
	if policy := s.resolveSelfRoutePolicy(r); policy.enabled {
		entries := filterEntriesByKeyAllowList(s.selfRouteModelEntries(policy.ownerAccountID, true), apiKeyFromContext(r.Context()))
		for _, entry := range entries {
			if entry.ID == id {
				writeJSON(w, http.StatusOK, entry)
				return
			}
		}
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q not found", id), withParam("model")))
		return
	}
	data, err := s.listModelEntries(true)
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list models"))
		return
	}
	for _, entry := range data {
		if entry.ID == id {
			writeJSON(w, http.StatusOK, entry)
			return
		}
	}
	writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
		fmt.Sprintf("model %q not found", id), withParam("model")))
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
