package catalog

import (
	"encoding/json"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type registerModelRequest struct {
	HuggingFaceArtifact          *store.HuggingFaceArtifact `json:"hugging_face_artifact,omitempty"`
	ModelID                      string                     `json:"model_id"`
	Version                      string                     `json:"version"`
	DisplayName                  string                     `json:"display_name"`
	Family                       string                     `json:"family"`
	Architecture                 string                     `json:"architecture"`
	Quantization                 string                     `json:"quantization"`
	MaxContextLength             int                        `json:"max_context_length"`
	MaxOutputLength              int                        `json:"max_output_length"`
	MinRAMGB                     int                        `json:"min_ram_gb"`
	Capabilities                 []string                   `json:"capabilities"`
	RequiredProviderCapabilities []string                   `json:"required_provider_capabilities"`
	Description                  string                     `json:"description"`
	RuntimeParameters            map[string]any             `json:"runtime_parameters"`
	Metadata                     map[string]any             `json:"metadata"`
	Promote                      bool                       `json:"promote"`
	InputPrice                   int64                      `json:"input_price"`  // micro-USD per 1M tokens (required)
	OutputPrice                  int64                      `json:"output_price"` // micro-USD per 1M tokens (required)
}

func (s *Controller) RegisterModel(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.requirePublishingAPIKey(w, r)
	if !ok {
		return
	}

	var req registerModelRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if err := validateRegisterModelRequest(req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", err.Error()))
		return
	}

	// Reverse namespace guard (mirror of the alias upsert's collision check): a
	// concrete model id must not collide with an existing public alias, or the
	// alias map would hijack raw-id requests for the new model at resolution.
	if _, found, err := s.store().GetModelAlias(req.ModelID); err == nil && found {
		httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("invalid_request_error",
			"model_id collides with an existing public alias", httpresponse.WithParam("model_id")))
		return
	}

	r2Prefix := ModelR2Prefix(req.ModelID, req.Version)
	manifest, err := fetchModelManifest(r.Context(), registryCDNBaseURL(), r2Prefix)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "failed to fetch manifest: "+err.Error()))
		return
	}
	if err := validateModelManifest(manifest, req.ModelID, req.Version, r2Prefix); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", err.Error()))
		return
	}
	if err := verifyManifestFiles(r.Context(), registryCDNBaseURL(), manifest, s.logger); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "manifest file verification failed: "+err.Error()))
		return
	}

	entry := &store.ModelRegistryEntry{
		ID:               req.ModelID,
		DisplayName:      req.DisplayName,
		Family:           req.Family,
		Architecture:     req.Architecture,
		Quantization:     req.Quantization,
		MaxContextLength: req.MaxContextLength,
		MaxOutputLength:  req.MaxOutputLength,
		MinRAMGB:         req.MinRAMGB,
		Capabilities:     req.Capabilities,
		RequiredProviderCapabilities: append(
			[]string{}, req.RequiredProviderCapabilities...),
		Status:            "beta",
		Description:       req.Description,
		RuntimeParameters: req.RuntimeParameters,
		Metadata:          req.Metadata,
	}
	if entry.DisplayName == "" {
		entry.DisplayName = req.ModelID
	}
	version := &store.ModelVersion{
		HuggingFaceArtifact: req.HuggingFaceArtifact,
		ModelID:             req.ModelID,
		Version:             req.Version,
		R2Prefix:            r2Prefix,
		AggregateSHA256:     manifest.AggregateSHA256,
		TotalSizeBytes:      manifest.TotalSizeBytes,
		FileCount:           manifest.FileCount,
		Status:              "ready",
		UploadedBy:          actor.Name,
		Metadata:            req.Metadata,
	}
	files := make([]store.ModelVersionFile, len(manifest.Files))
	for i, f := range manifest.Files {
		files[i] = store.ModelVersionFile{Path: f.Path, SizeBytes: f.SizeBytes, SHA256: f.SHA256, Role: f.Role}
	}
	if err := s.store().SetModelVersion(entry, version, files); err != nil {
		s.logger.Error("model registry: register failed", "model_id", req.ModelID, "version", req.Version, "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to save model version"))
		return
	}
	// Set platform pricing for this model.
	if err := s.store().SetModelPrice("platform", req.ModelID, req.InputPrice, req.OutputPrice); err != nil {
		s.logger.Error("model registry: set pricing failed", "model_id", req.ModelID, "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "model registered but failed to set pricing"))
		return
	}

	if req.Promote {
		if err := s.store().PromoteModelVersion(req.ModelID, req.Version); err != nil {
			s.logger.Error("model registry: promote after register failed", "model_id", req.ModelID, "version", req.Version, "error", err)
			s.writeModelRegistryStoreError(w, "promote model version", err)
			return
		}
	}
	s.syncCatalog()

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"status":       "registered",
		"model":        entry,
		"version":      version,
		"files":        len(files),
		"input_price":  req.InputPrice,
		"output_price": req.OutputPrice,
	})
}
