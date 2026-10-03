package catalog

import (
	"encoding/json"
	"errors"
	"net/http"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/api/modelprice"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const defaultModelRegistryCDNBaseURL = "https://models.darkbloom.ai"

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
	// Platform price written at registration: input_price and output_price are
	// required; cache_read_price is optional (see modelprice.Input).
	modelprice.Input
}

// registerModelResponse is the POST /v1/admin/models/register response: the
// stored registry entry and version plus the platform price as it will settle.
type registerModelResponse struct {
	Status  string                    `json:"status"`
	Model   *store.ModelRegistryEntry `json:"model"`
	Version *store.ModelVersion       `json:"version"`
	Files   int                       `json:"files"`
	types.ModelPriceQuote
}

func (s *Owner) HandleModelCatalogItem(w http.ResponseWriter, r *http.Request) {
	modelID, ok := parseModelCatalogPath(r.URL.Path)
	if !ok || modelID == "" {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "model not found"))
		return
	}
	rec, err := s.store.GetModelRegistryRecord(modelID)
	if err != nil {
		s.writeModelRegistryStoreError(w, "get model", err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, catalogModelFromRegistryRecord(rec))
}

func (s *Owner) HandleModelCatalogManifest(w http.ResponseWriter, r *http.Request) {
	modelID, ok := parseModelCatalogManifestPath(r.URL.Path)
	if !ok || modelID == "" {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "model manifest not found"))
		return
	}
	m, err := s.store.GetModelManifest(modelID)
	if err != nil {
		s.writeModelRegistryStoreError(w, "get manifest", err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, m)
}

func (s *Owner) HandleRegisterModel(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.access.RequirePublishingAPIKey(w, r)
	if !ok {
		return
	}

	var req registerModelRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if err := validateRegisterModelRequest(req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}

	// Reverse namespace guard (mirror of the alias upsert's collision check): a
	// concrete model id must not collide with an existing public alias, or the
	// alias map would hijack raw-id requests for the new model at resolution.
	if _, found, err := s.store.GetModelAlias(req.ModelID); err == nil && found {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error",
			"model_id collides with an existing public alias", httpx.WithParam("model_id")))
		return
	}

	r2Prefix := modelR2Prefix(req.ModelID, req.Version)
	manifest, err := fetchModelManifest(r.Context(), registryCDNBaseURL(), r2Prefix)
	if err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "failed to fetch manifest: "+err.Error()))
		return
	}
	if err := validateModelManifest(manifest, req.ModelID, req.Version, r2Prefix); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}
	if err := verifyManifestFiles(r.Context(), registryCDNBaseURL(), manifest, s.logger); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "manifest file verification failed: "+err.Error()))
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
	if err := s.store.SetModelVersion(entry, version, files); err != nil {
		if errors.Is(err, store.ErrModelVersionImmutable) {
			httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error", err.Error()))
			return
		}
		s.logger.Error("model registry: register failed", "model_id", req.ModelID, "version", req.Version, "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to save model version"))
		return
	}
	// Set platform pricing for this model.
	price := req.ModelPrice("platform", req.ModelID)
	if err := s.store.SetModelPrice(price); err != nil {
		s.logger.Error("model registry: set pricing failed", "model_id", req.ModelID, "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "model registered but failed to set pricing"))
		return
	}

	if req.Promote {
		if err := s.store.PromoteModelVersion(req.ModelID, req.Version); err != nil {
			s.logger.Error("model registry: promote after register failed", "model_id", req.ModelID, "version", req.Version, "error", err)
			s.writeModelRegistryStoreError(w, "promote model version", err)
			return
		}
	}
	s.SyncModelCatalog()
	httpx.WriteJSON(w, http.StatusOK, registerModelResponse{
		Status:          "registered",
		Model:           entry,
		Version:         version,
		Files:           len(files),
		ModelPriceQuote: modelprice.Quote(price),
	})
}
