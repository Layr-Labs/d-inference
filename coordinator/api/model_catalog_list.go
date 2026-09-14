package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// handleModelCatalog handles GET /v1/models/catalog.
// Public endpoint — returns active models for providers and the install script.
// Cached for 60s — the underlying DB query is fast but this endpoint is hit
// by every provider heartbeat and install script poll.
func modelCatalogCacheKey(typeFilter string, includeAliases bool) string {
	return "models:catalog:type=" + typeFilter + ":include_aliases=" + strconv.FormatBool(includeAliases)
}

func (s *Server) handleModelCatalog(w http.ResponseWriter, r *http.Request) {
	// Optional filter: ?type=text
	typeFilter := strings.TrimSpace(strings.ToLower(r.URL.Query().Get("type")))
	if typeFilter != "" && typeFilter != "text" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "unsupported catalog type", withParam("type")))
		return
	}
	includeAliases := r.URL.Query().Get("include_aliases") == "1" || strings.EqualFold(r.URL.Query().Get("include_aliases"), "true")

	cacheKey := modelCatalogCacheKey(typeFilter, includeAliases)
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	registryRows, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch model catalog"))
		return
	}
	// The catalog is text-only today; an explicit non-text filter yields nothing.
	models := make([]map[string]any, 0, len(registryRows))
	if typeFilter == "" || typeFilter == "text" {
		for i := range registryRows {
			models = append(models, catalogModelFromRegistryRecord(&registryRows[i]))
		}
	}
	response := map[string]any{"models": models}
	if includeAliases {
		aliases, err := s.store.ListModelAliases()
		if err != nil {
			s.logger.Warn("model registry: failed to list aliases for catalog response", "error", err)
		} else {
			response["aliases"] = catalogAliasesForResponse(models, aliases)
		}
	}

	body, err := json.Marshal(response)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to marshal catalog"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}
