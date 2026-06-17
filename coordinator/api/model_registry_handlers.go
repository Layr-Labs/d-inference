package api

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const defaultModelRegistryCDNBaseURL = "https://models.darkbloom.ai"

type registerModelRequest struct {
	ModelID           string         `json:"model_id"`
	Version           string         `json:"version"`
	DisplayName       string         `json:"display_name"`
	Family            string         `json:"family"`
	Architecture      string         `json:"architecture"`
	Quantization      string         `json:"quantization"`
	MaxContextLength  int            `json:"max_context_length"`
	MaxOutputLength   int            `json:"max_output_length"`
	MinRAMGB          int            `json:"min_ram_gb"`
	Capabilities      []string       `json:"capabilities"`
	Description       string         `json:"description"`
	RuntimeParameters map[string]any `json:"runtime_parameters"`
	Metadata          map[string]any `json:"metadata"`
	Promote           bool           `json:"promote"`
	InputPrice        int64          `json:"input_price"`  // micro-USD per 1M tokens (required)
	OutputPrice       int64          `json:"output_price"` // micro-USD per 1M tokens (required)
}

type publishingActor struct {
	ID   string
	Name string
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

func (s *Server) handleRegisterModel(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.requirePublishingAPIKey(w, r)
	if !ok {
		return
	}

	var req registerModelRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if err := validateRegisterModelRequest(req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}

	// Reverse namespace guard (mirror of the alias upsert's collision check): a
	// concrete model id must not collide with an existing public alias, or the
	// alias map would hijack raw-id requests for the new model at resolution.
	if _, found, err := s.store.GetModelAlias(req.ModelID); err == nil && found {
		writeJSON(w, http.StatusConflict, errorResponse("invalid_request_error",
			"model_id collides with an existing public alias", withParam("model_id")))
		return
	}

	r2Prefix := modelR2Prefix(req.ModelID, req.Version)
	manifest, err := fetchModelManifest(r.Context(), registryCDNBaseURL(), r2Prefix)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to fetch manifest: "+err.Error()))
		return
	}
	if err := validateModelManifest(manifest, req.ModelID, req.Version, r2Prefix); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if err := verifyManifestFiles(r.Context(), registryCDNBaseURL(), manifest, s.logger); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "manifest file verification failed: "+err.Error()))
		return
	}

	entry := &store.ModelRegistryEntry{
		ID:                req.ModelID,
		DisplayName:       req.DisplayName,
		Family:            req.Family,
		Architecture:      req.Architecture,
		Quantization:      req.Quantization,
		MaxContextLength:  req.MaxContextLength,
		MaxOutputLength:   req.MaxOutputLength,
		MinRAMGB:          req.MinRAMGB,
		Capabilities:      req.Capabilities,
		Status:            "beta",
		Description:       req.Description,
		RuntimeParameters: req.RuntimeParameters,
		Metadata:          req.Metadata,
	}
	if entry.DisplayName == "" {
		entry.DisplayName = req.ModelID
	}
	version := &store.ModelVersion{
		ModelID:         req.ModelID,
		Version:         req.Version,
		R2Prefix:        r2Prefix,
		AggregateSHA256: manifest.AggregateSHA256,
		TotalSizeBytes:  manifest.TotalSizeBytes,
		FileCount:       manifest.FileCount,
		Status:          "ready",
		UploadedBy:      actor.Name,
		Metadata:        req.Metadata,
	}
	files := make([]store.ModelVersionFile, len(manifest.Files))
	for i, f := range manifest.Files {
		files[i] = store.ModelVersionFile{Path: f.Path, SizeBytes: f.SizeBytes, SHA256: f.SHA256, Role: f.Role}
	}
	if err := s.store.SetModelVersion(entry, version, files); err != nil {
		s.logger.Error("model registry: register failed", "model_id", req.ModelID, "version", req.Version, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to save model version"))
		return
	}
	// Set platform pricing for this model.
	if err := s.store.SetModelPrice("platform", req.ModelID, req.InputPrice, req.OutputPrice); err != nil {
		s.logger.Error("model registry: set pricing failed", "model_id", req.ModelID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "model registered but failed to set pricing"))
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

	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "registered",
		"model":        entry,
		"version":      version,
		"files":        len(files),
		"input_price":  req.InputPrice,
		"output_price": req.OutputPrice,
	})
}

func (s *Server) handleAdminModelRegistryAction(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	modelID, action, ok := parseAdminModelActionPath(r.URL.Path)
	if !ok || modelID == "" {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "model action not found"))
		return
	}
	switch action {
	case "promote":
		var req struct {
			Version string `json:"version"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		if req.Version == "" || strings.Contains(req.Version, "/") || containsTraversal(req.Version) {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "valid version is required"))
			return
		}
		if err := s.store.PromoteModelVersion(modelID, req.Version); err != nil {
			s.writeModelRegistryStoreError(w, "promote model version", err)
			return
		}
		s.SyncModelCatalog()
		writeJSON(w, http.StatusOK, map[string]any{"status": "promoted", "model_id": modelID, "version": req.Version})
	case "status":
		var req struct {
			Status string `json:"status"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		if !validModelStatus(req.Status) {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "status must be beta, active, deprecated, or retired"))
			return
		}
		if err := s.store.SetModelStatus(modelID, req.Status); err != nil {
			s.writeModelRegistryStoreError(w, "set model status", err)
			return
		}
		s.SyncModelCatalog()
		writeJSON(w, http.StatusOK, map[string]any{"status": "updated", "model_id": modelID, "model_status": req.Status})
	case "runtime-parameters":
		var req struct {
			RuntimeParameters map[string]any `json:"runtime_parameters"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		if req.RuntimeParameters == nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "runtime_parameters is required"))
			return
		}
		rec, err := s.store.GetModelRegistryRecord(modelID)
		if err != nil {
			s.writeModelRegistryStoreError(w, "get model for runtime_parameters update", err)
			return
		}
		// Merge new parameters into existing ones (allows partial updates).
		if rec.RuntimeParameters == nil {
			rec.RuntimeParameters = make(map[string]any)
		}
		for k, v := range req.RuntimeParameters {
			rec.RuntimeParameters[k] = v
		}
		entry := registryEntryFromRecord(rec)
		if err := s.store.UpsertModelRegistryEntry(entry); err != nil {
			s.writeModelRegistryStoreError(w, "update runtime_parameters", err)
			return
		}
		s.SyncModelCatalog()
		writeJSON(w, http.StatusOK, map[string]any{
			"status":             "updated",
			"model_id":           modelID,
			"runtime_parameters": rec.RuntimeParameters,
		})
	case "capabilities":
		var req struct {
			Capabilities []string `json:"capabilities"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		if req.Capabilities == nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "capabilities is required (array of strings)"))
			return
		}
		rec, err := s.store.GetModelRegistryRecord(modelID)
		if err != nil {
			s.writeModelRegistryStoreError(w, "get model for capabilities update", err)
			return
		}
		// Replace capabilities wholesale (normalized: trimmed, de-duped, ordered).
		caps := normalizeCapabilities(req.Capabilities)
		entry := registryEntryFromRecord(rec)
		entry.Capabilities = caps
		if err := s.store.UpsertModelRegistryEntry(entry); err != nil {
			s.writeModelRegistryStoreError(w, "update capabilities", err)
			return
		}
		s.SyncModelCatalog()
		writeJSON(w, http.StatusOK, map[string]any{
			"status":       "updated",
			"model_id":     modelID,
			"capabilities": caps,
		})
	case "deprecation":
		// Sets (or clears) the OpenRouter deprecation_date in model metadata.
		// An omitted/empty deprecation_date clears it — i.e. clear by default —
		// so an empty body or {} removes any existing deprecation date.
		var req struct {
			DeprecationDate string `json:"deprecation_date"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && err != io.EOF {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		date := strings.TrimSpace(req.DeprecationDate)
		if date != "" {
			if _, perr := time.Parse("2006-01-02", date); perr != nil {
				writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
					"deprecation_date must be an ISO 8601 date (YYYY-MM-DD)", withParam("deprecation_date")))
				return
			}
		}
		rec, err := s.store.GetModelRegistryRecord(modelID)
		if err != nil {
			s.writeModelRegistryStoreError(w, "get model for deprecation update", err)
			return
		}
		entry := registryEntryFromRecord(rec)
		// Clone metadata before mutating so the stored record is never aliased.
		meta := make(map[string]any, len(entry.Metadata))
		for k, v := range entry.Metadata {
			meta[k] = v
		}
		if date == "" {
			delete(meta, "deprecation_date")
		} else {
			meta["deprecation_date"] = date
		}
		entry.Metadata = meta
		if err := s.store.UpsertModelRegistryEntry(entry); err != nil {
			s.writeModelRegistryStoreError(w, "update deprecation_date", err)
			return
		}
		s.SyncModelCatalog()
		resp := map[string]any{"status": "updated", "model_id": modelID}
		if date == "" {
			resp["deprecation_date"] = nil
			resp["note"] = "deprecation date cleared"
		} else {
			resp["deprecation_date"] = date
		}
		writeJSON(w, http.StatusOK, resp)
	case "openrouter-slug":
		// Sets (or clears) the OpenRouter marketplace slug in model metadata.
		// An omitted/empty slug clears the override — clear by default — so the
		// feed falls back to the model id. Use this to map a model onto an
		// existing OpenRouter slug (e.g. "qwen/qwen3.5-9b").
		var req struct {
			Slug string `json:"slug"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && err != io.EOF {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		slug := strings.TrimSpace(req.Slug)
		rec, err := s.store.GetModelRegistryRecord(modelID)
		if err != nil {
			s.writeModelRegistryStoreError(w, "get model for openrouter-slug update", err)
			return
		}
		entry := registryEntryFromRecord(rec)
		meta := make(map[string]any, len(entry.Metadata))
		for k, v := range entry.Metadata {
			meta[k] = v
		}
		if slug == "" {
			delete(meta, "openrouter_slug")
		} else {
			meta["openrouter_slug"] = slug
		}
		entry.Metadata = meta
		if err := s.store.UpsertModelRegistryEntry(entry); err != nil {
			s.writeModelRegistryStoreError(w, "update openrouter-slug", err)
			return
		}
		s.SyncModelCatalog()
		resp := map[string]any{"status": "updated", "model_id": modelID}
		if slug == "" {
			resp["openrouter_slug"] = nil
			resp["note"] = "openrouter slug cleared — feed falls back to the model id"
		} else {
			resp["openrouter_slug"] = slug
		}
		writeJSON(w, http.StatusOK, resp)
	default:
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "model action not found"))
	}
}
