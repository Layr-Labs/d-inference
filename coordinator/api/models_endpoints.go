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
// public aliases and returns the set of underlying build ids those aliases
// cover (so the caller can hide them from the default listing). The hidden set
// covers EVERY build an alias references — desired, previous, and the retired
// lineage — so a concrete quant build never appears as its own entry once it is
// behind an alias. Each alias entry derives its metadata from its primary build
// — the desired build, or the previous build if the desired one isn't in the
// catalog yet — and aggregates live capacity across the desired and previous
// builds so the alias's routable/warm counts reflect every quant currently
// serving it (retired builds are hide-only and never contribute capacity).
func (s *Server) aliasModelEntries(
	capByModel map[string]*registry.ModelCapacity,
	catalogByID map[string]store.SupportedModel,
	registryByID map[string]store.ModelRegistryEntry,
) ([]types.ModelEntry, map[string]struct{}) {
	hidden := make(map[string]struct{})
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.logger.Error("model registry: failed to list aliases", "error", err)
		return nil, hidden
	}

	entries := make([]types.ModelEntry, 0, len(aliases))
	for _, a := range aliases {
		if !a.Active || a.DesiredBuild == "" {
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
			ID:       a.AliasID,
			Object:   "model",
			OwnedBy:  "eigeninference",
			Name:     displayName,
			Metadata: metadata,
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
	}
	return entries, hidden
}

// listModelEntries assembles the consumer-facing model entries shared by
// GET /v1/models and GET /v1/models/{id}. includeBuilds also lists the raw
// quant builds hidden behind public aliases (ops/debug).
func (s *Server) listModelEntries(includeBuilds bool) ([]types.ModelEntry, error) {
	models := s.registry.ListModels()

	// Build a lookup of capacity data keyed by model ID.
	capacities := s.registry.ModelCapacitySnapshot()
	capByModel := make(map[string]*registry.ModelCapacity, len(capacities))
	for i := range capacities {
		capByModel[capacities[i].ModelID] = &capacities[i]
	}

	// Filter to only show models from the active catalog, and capture the richer
	// registry entries used to populate the OpenRouter provider fields. These
	// lookups are shared with the dedicated /v1/models/openrouter feed.
	catalogByID, registryByID, err := s.activeCatalogLookups()
	if err != nil {
		return nil, err
	}

	// Public aliases are the consumer-facing model names; their underlying
	// quant builds are hidden by default so consumers never see the quant.
	aliasEntries, hiddenBuilds := s.aliasModelEntries(capByModel, catalogByID, registryByID)

	data := make([]types.ModelEntry, 0, len(models)+len(aliasEntries))
	data = append(data, aliasEntries...)
	for _, m := range models {
		cm, inCatalog := catalogByID[m.ID]
		if len(catalogByID) > 0 && !inCatalog {
			continue
		}
		if _, hidden := hiddenBuilds[m.ID]; hidden && !includeBuilds {
			continue
		}
		metadata := types.ModelMetadata{
			ModelType:         m.ModelType,
			Quantization:      m.Quantization,
			ProviderCount:     m.Providers,
			AttestedProviders: m.AttestedProviders,
			TrustLevel:        string(m.TrustLevel),
		}
		// Add capacity fields from live snapshot.
		if cap, ok := capByModel[m.ID]; ok {
			metadata.RoutableProviders = cap.RoutableProviders
			metadata.WarmProviders = cap.WarmProviders
			metadata.CanAccept = cap.CanAccept
		} else {
			metadata.RoutableProviders = 0
			metadata.WarmProviders = 0
			metadata.CanAccept = false
		}
		if m.Attestation != nil {
			metadata.Attestation = &types.ModelAttestation{
				SecureEnclave: m.Attestation.SecureEnclave,
				SIPEnabled:    m.Attestation.SIPEnabled,
				SecureBoot:    m.Attestation.SecureBoot,
			}
		}
		if inCatalog && cm.DisplayName != "" {
			metadata.DisplayName = cm.DisplayName
		}

		entry := types.ModelEntry{
			ID:            m.ID,
			Object:        "model",
			Created:       0,
			OwnedBy:       "eigeninference",
			Name:          metadata.DisplayName,
			HuggingFaceID: m.ID, // model IDs are HuggingFace paths
			Metadata:      metadata,
		}

		// OpenRouter provider fields (quantization, per-token pricing, sampling
		// params, and registry-sourced metadata), shared with the dedicated
		// /v1/models/openrouter feed.
		reg, hasReg := registryByID[m.ID]
		s.openRouterModelFieldsFor(m.ID, m.Quantization, reg, hasReg).applyToModelEntry(&entry)

		// Modalities are derived from the model's capabilities (text by default).
		var caps []string
		if hasReg {
			caps = reg.Capabilities
		}
		entry.InputModalities, entry.OutputModalities = deriveModalities(m.ModelType, caps)

		data = append(data, entry)
	}

	return data, nil
}

func (s *Server) handleListModels(w http.ResponseWriter, r *http.Request) {
	if k := apiKeyFromContext(r.Context()); k != nil && k.SelfRouteOnly {
		writeJSON(w, http.StatusOK, types.ModelListResponse{
			Object: "list",
			Data:   s.selfRouteModelEntries(consumerKeyFromContext(r.Context())),
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

func (s *Server) selfRouteModelEntries(accountID string) []types.ModelEntry {
	models := s.registry.OwnedModels(accountID)
	data := make([]types.ModelEntry, 0, len(models))
	for _, m := range models {
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
		data = append(data, types.ModelEntry{
			ID:            m.ID,
			Object:        "model",
			OwnedBy:       "self",
			Name:          m.ID,
			HuggingFaceID: m.ID,
			Quantization:  m.Quantization,
			Metadata:      metadata,
		})
	}
	return data
}

// handleGetModel handles GET /v1/models/{id...} — the OpenAI "retrieve model"
// endpoint. Model IDs may contain slashes (HuggingFace paths), hence the
// wildcard path segment. Hidden quant builds are retrievable by their exact
// id, matching the behavior of requesting one for inference.
func (s *Server) handleGetModel(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
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
