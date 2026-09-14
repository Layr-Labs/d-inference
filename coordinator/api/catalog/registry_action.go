package catalog

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

func (s *Controller) AdminModelAction(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	modelID, action, ok := parseAdminModelActionPath(r.URL.Path)
	if !ok || modelID == "" {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "model action not found"))
		return
	}
	switch action {
	case "promote":
		var req struct {
			Version string `json:"version"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		if req.Version == "" || strings.Contains(req.Version, "/") || containsTraversal(req.Version) {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "valid version is required"))
			return
		}
		if err := s.store().PromoteModelVersion(modelID, req.Version); err != nil {
			s.writeModelRegistryStoreError(w, "promote model version", err)
			return
		}
		s.syncCatalog()
		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"status": "promoted", "model_id": modelID, "version": req.Version})
	case "status":
		var req struct {
			Status string `json:"status"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		if !validModelStatus(req.Status) {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "status must be beta, active, deprecated, or retired"))
			return
		}
		if err := s.store().SetModelStatus(modelID, req.Status); err != nil {
			s.writeModelRegistryStoreError(w, "set model status", err)
			return
		}
		s.syncCatalog()
		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"status": "updated", "model_id": modelID, "model_status": req.Status})
	case "runtime-parameters":
		var req struct {
			RuntimeParameters map[string]any `json:"runtime_parameters"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		if req.RuntimeParameters == nil {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "runtime_parameters is required"))
			return
		}
		rec, err := s.store().GetModelRegistryRecord(modelID)
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
		if err := s.store().UpsertModelRegistryEntry(entry); err != nil {
			s.writeModelRegistryStoreError(w, "update runtime_parameters", err)
			return
		}
		s.syncCatalog()
		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
			"status":             "updated",
			"model_id":           modelID,
			"runtime_parameters": rec.RuntimeParameters,
		})
	case "capabilities":
		var req struct {
			Capabilities []string `json:"capabilities"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		if req.Capabilities == nil {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "capabilities is required (array of strings)"))
			return
		}
		rec, err := s.store().GetModelRegistryRecord(modelID)
		if err != nil {
			s.writeModelRegistryStoreError(w, "get model for capabilities update", err)
			return
		}
		// Replace capabilities wholesale (normalized: trimmed, de-duped, ordered).
		caps := normalizeCapabilities(req.Capabilities)
		entry := registryEntryFromRecord(rec)
		entry.Capabilities = caps
		if err := s.store().UpsertModelRegistryEntry(entry); err != nil {
			s.writeModelRegistryStoreError(w, "update capabilities", err)
			return
		}
		s.syncCatalog()
		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
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
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		date := strings.TrimSpace(req.DeprecationDate)
		if date != "" {
			if _, perr := time.Parse("2006-01-02", date); perr != nil {
				httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
					"deprecation_date must be an ISO 8601 date (YYYY-MM-DD)", httpresponse.WithParam("deprecation_date")))
				return
			}
		}
		rec, err := s.store().GetModelRegistryRecord(modelID)
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
		if err := s.store().UpsertModelRegistryEntry(entry); err != nil {
			s.writeModelRegistryStoreError(w, "update deprecation_date", err)
			return
		}
		s.syncCatalog()
		resp := map[string]any{"status": "updated", "model_id": modelID}
		if date == "" {
			resp["deprecation_date"] = nil
			resp["note"] = "deprecation date cleared"
		} else {
			resp["deprecation_date"] = date
		}
		httpresponse.WriteJSON(w, http.StatusOK, resp)
	case "openrouter-slug":
		// Sets (or clears) the OpenRouter marketplace slug in model metadata.
		// An omitted/empty slug clears the override — clear by default — so the
		// feed falls back to the model id. Use this to map a model onto an
		// existing OpenRouter slug (e.g. "qwen/qwen3.5-9b").
		var req struct {
			Slug string `json:"slug"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && err != io.EOF {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		slug := strings.TrimSpace(req.Slug)
		rec, err := s.store().GetModelRegistryRecord(modelID)
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
		if err := s.store().UpsertModelRegistryEntry(entry); err != nil {
			s.writeModelRegistryStoreError(w, "update openrouter-slug", err)
			return
		}
		s.syncCatalog()
		resp := map[string]any{"status": "updated", "model_id": modelID}
		if slug == "" {
			resp["openrouter_slug"] = nil
			resp["note"] = "openrouter slug cleared — feed falls back to the model id"
		} else {
			resp["openrouter_slug"] = slug
		}
		httpresponse.WriteJSON(w, http.StatusOK, resp)
	case "hugging-face-id":
		// Sets (or clears) the exact Hugging Face repository exposed in model
		// feeds. Internal routing ids need not be valid Hugging Face paths.
		var req struct {
			HuggingFaceID string `json:"hugging_face_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && err != io.EOF {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
		huggingFaceID := strings.TrimSpace(req.HuggingFaceID)
		rec, err := s.store().GetModelRegistryRecord(modelID)
		if err != nil {
			s.writeModelRegistryStoreError(w, "get model for hugging-face-id update", err)
			return
		}
		entry := registryEntryFromRecord(rec)
		meta := make(map[string]any, len(entry.Metadata))
		for k, v := range entry.Metadata {
			meta[k] = v
		}
		if huggingFaceID == "" {
			delete(meta, huggingFaceIDMetadataKey)
		} else {
			meta[huggingFaceIDMetadataKey] = huggingFaceID
		}
		entry.Metadata = meta
		if err := s.store().UpsertModelRegistryEntry(entry); err != nil {
			s.writeModelRegistryStoreError(w, "update hugging-face-id", err)
			return
		}
		s.syncCatalog()
		resp := map[string]any{"status": "updated", "model_id": modelID}
		if huggingFaceID == "" {
			resp["hugging_face_id"] = nil
			resp["note"] = "Hugging Face ID cleared — feed falls back to the model id"
		} else {
			resp["hugging_face_id"] = huggingFaceID
		}
		httpresponse.WriteJSON(w, http.StatusOK, resp)
	default:
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "model action not found"))
	}
}

func parseAdminModelActionPath(p string) (string, string, bool) {
	rest := strings.TrimPrefix(p, "/v1/admin/models/")
	if rest == p || rest == "" {
		return "", "", false
	}
	for _, action := range []string{"/promote", "/status", "/runtime-parameters", "/capabilities", "/deprecation", "/openrouter-slug", "/hugging-face-id"} {
		if strings.HasSuffix(rest, action) {
			modelID, err := url.PathUnescape(strings.TrimSuffix(rest, action))
			if err != nil {
				return "", "", false
			}
			return modelID, strings.TrimPrefix(action, "/"), true
		}
	}
	return "", "", false
}
