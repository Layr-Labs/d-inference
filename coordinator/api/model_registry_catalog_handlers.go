package api

import (
	"net/http"
	"time"
)

// handleModelCatalog handles GET /v1/models/catalog.
// Public endpoint — returns active models for providers and the install script.
// Cached for 60s — the underlying DB query is fast but this endpoint is hit
// by every provider heartbeat and install script poll.
func (s *Server) handleModelCatalog(w http.ResponseWriter, r *http.Request) {
	// Optional filter: ?type=text
	typeFilter := r.URL.Query().Get("type")

	cacheKey := "models:catalog"
	if typeFilter != "" {
		cacheKey = "models:catalog:" + typeFilter
	}
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

	s.writeCachedJSONResult(w, cacheKey, time.Minute, response, "failed to marshal catalog")
}

func (s *Server) handleModelCatalogItem(w http.ResponseWriter, r *http.Request) {
	modelID, ok := parseModelCatalogPath(r.URL.Path)
	if !ok || modelID == "" {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "model not found"))
		return
	}
	rec, err := s.store.GetModelRegistryRecord(modelID)
	if err != nil {
		s.writeModelRegistryStoreError(w, "get model", err)
		return
	}
	writeJSON(w, http.StatusOK, catalogModelFromRegistryRecord(rec))
}

func (s *Server) handleModelCatalogManifest(w http.ResponseWriter, r *http.Request) {
	modelID, ok := parseModelCatalogManifestPath(r.URL.Path)
	if !ok || modelID == "" {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "model manifest not found"))
		return
	}
	m, err := s.store.GetModelManifest(modelID)
	if err != nil {
		s.writeModelRegistryStoreError(w, "get manifest", err)
		return
	}
	writeJSON(w, http.StatusOK, m)
}
