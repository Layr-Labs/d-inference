package catalog

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	registration "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/registration"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Publishing new bytes for an existing model should not require resubmitting
// pricing, aliases or capability metadata. The manifest is uploaded last; this
// endpoint verifies it, records its immutable identity, and promotes it.
func (s *Owner) handlePublishModelRevision(w http.ResponseWriter, r *http.Request, modelID string, actor access.PublishingActor) {
	var req struct {
		Version             string                     `json:"version"`
		HuggingFaceArtifact *store.HuggingFaceArtifact `json:"hugging_face_artifact,omitempty"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil || req.Version == "" || strings.Contains(req.Version, "/") || registration.ContainsTraversal(req.Version) {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "valid version is required"))
		return
	}
	if err := req.HuggingFaceArtifact.Validate(); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}
	record, err := s.store.GetModelRegistryRecord(modelID)
	if err != nil {
		s.writeModelRegistryStoreError(w, "get model for revision", err)
		return
	}
	prefix := registration.ModelR2Prefix(modelID, req.Version)
	manifest, err := fetchModelManifest(r.Context(), registration.RegistryCDNBaseURL(), prefix)
	if err == nil {
		err = registration.ValidateModelManifest(manifest, modelID, req.Version, prefix)
	}
	if err == nil {
		err = verifyManifestFiles(r.Context(), registration.RegistryCDNBaseURL(), manifest, s.logger)
	}
	if err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "revision verification failed: "+err.Error()))
		return
	}
	version := &store.ModelVersion{
		ModelID: modelID, Version: req.Version, R2Prefix: prefix,
		AggregateSHA256: manifest.AggregateSHA256, TotalSizeBytes: manifest.TotalSizeBytes,
		FileCount: manifest.FileCount, Status: "ready", Metadata: record.Metadata,
		UploadedBy: actor.Name, HuggingFaceArtifact: req.HuggingFaceArtifact,
	}
	// New versions declare their own pinned HF source; omission selects R2-only
	// instead of inheriting another version's locator. Identical-version retries
	// retain the currently stored locator, including explicit registration edits.
	files := make([]store.ModelVersionFile, len(manifest.Files))
	for i, f := range manifest.Files {
		files[i] = store.ModelVersionFile{Path: f.Path, SizeBytes: f.SizeBytes, SHA256: f.SHA256, Role: f.Role}
	}
	if err := s.store.SetExistingModelVersion(version, files); err != nil {
		if errors.Is(err, store.ErrModelVersionImmutable) {
			httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error", err.Error()))
		} else {
			s.writeModelRegistryStoreError(w, "save model revision", err)
		}
		return
	}
	if err := s.store.PromoteModelVersion(modelID, req.Version); err != nil {
		s.writeModelRegistryStoreError(w, "promote model revision", err)
		return
	}
	if !s.Sync() {
		w.Header().Set("Retry-After", "5")
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("internal_error", "revision promoted in storage but live policy refresh or provider delivery failed; retry publication with the same version"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"status": "promoted", "model_id": modelID, "version": req.Version,
		"aggregate_sha256": manifest.AggregateSHA256,
	})
}

func (s *Owner) handleRetireModelRevision(w http.ResponseWriter, r *http.Request, modelID string) {
	var req struct {
		Version string `json:"version"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil || req.Version == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "version is required"))
		return
	}
	if err := s.store.RetireModelVersion(modelID, req.Version); err != nil {
		if errors.Is(err, store.ErrActiveModelVersion) {
			httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error", err.Error()))
		} else {
			s.writeModelRegistryStoreError(w, "retire model revision", err)
		}
		return
	}
	if !s.Sync() {
		w.Header().Set("Retry-After", "5")
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("internal_error", "revision retired in storage but live policy refresh or provider delivery failed; retry retirement"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"status": "retired", "model_id": modelID, "version": req.Version})
}
