package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Publishing new bytes for an existing model should not require resubmitting
// pricing, aliases or capability metadata. The manifest is uploaded last; this
// endpoint verifies it, records its immutable identity, and promotes it.
func (s *Server) handlePublishModelRevision(w http.ResponseWriter, r *http.Request, modelID string) {
	var req struct {
		Version string `json:"version"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil || req.Version == "" || strings.Contains(req.Version, "/") || containsTraversal(req.Version) {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "valid version is required"))
		return
	}
	record, err := s.store.GetModelRegistryRecord(modelID)
	if err != nil {
		s.writeModelRegistryStoreError(w, "get model for revision", err)
		return
	}
	prefix := modelR2Prefix(modelID, req.Version)
	manifest, err := fetchModelManifest(r.Context(), registryCDNBaseURL(), prefix)
	if err == nil {
		err = validateModelManifest(manifest, modelID, req.Version, prefix)
	}
	if err == nil {
		err = verifyManifestFiles(r.Context(), registryCDNBaseURL(), manifest, s.logger)
	}
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "revision verification failed: "+err.Error()))
		return
	}
	version := &store.ModelVersion{
		ModelID: modelID, Version: req.Version, R2Prefix: prefix,
		AggregateSHA256: manifest.AggregateSHA256, TotalSizeBytes: manifest.TotalSizeBytes,
		FileCount: manifest.FileCount, Status: "ready", Metadata: record.Metadata,
	}
	// A previous HF mirror points at previous bytes. The revision uses R2 until
	// an independently pinned, matching mirror is registered for this version.
	files := make([]store.ModelVersionFile, len(manifest.Files))
	for i, f := range manifest.Files {
		files[i] = store.ModelVersionFile{Path: f.Path, SizeBytes: f.SizeBytes, SHA256: f.SHA256, Role: f.Role}
	}
	if err := s.store.SetExistingModelVersion(version, files); err != nil {
		if errors.Is(err, store.ErrModelVersionImmutable) {
			writeJSON(w, http.StatusConflict, errorResponse("invalid_request_error", err.Error()))
		} else {
			s.writeModelRegistryStoreError(w, "save model revision", err)
		}
		return
	}
	if err := s.store.PromoteModelVersion(modelID, req.Version); err != nil {
		s.writeModelRegistryStoreError(w, "promote model revision", err)
		return
	}
	s.SyncModelCatalog()
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "promoted", "model_id": modelID, "version": req.Version,
		"aggregate_sha256": manifest.AggregateSHA256,
	})
}

func (s *Server) handleRetireModelRevision(w http.ResponseWriter, r *http.Request, modelID string) {
	var req struct {
		Version string `json:"version"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil || req.Version == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "version is required"))
		return
	}
	if err := s.store.RetireModelVersion(modelID, req.Version); err != nil {
		if errors.Is(err, store.ErrActiveModelVersion) {
			writeJSON(w, http.StatusConflict, errorResponse("invalid_request_error", err.Error()))
		} else {
			s.writeModelRegistryStoreError(w, "retire model revision", err)
		}
		return
	}
	if !s.syncModelCatalog() {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("internal_error", "revision retired in storage but live policy refresh failed; retry retirement"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "retired", "model_id": modelID, "version": req.Version})
}
