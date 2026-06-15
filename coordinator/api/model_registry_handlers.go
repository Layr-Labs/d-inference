package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
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

// registryEntryFromRecord copies the mutable model fields out of a stored
// record into a fresh ModelRegistryEntry, so an in-place admin update can
// change one field (e.g. capabilities or runtime parameters) and upsert it
// without dropping the others.
func registryEntryFromRecord(rec *store.ModelRegistryRecord) *store.ModelRegistryEntry {
	return &store.ModelRegistryEntry{
		ID:                rec.ID,
		DisplayName:       rec.DisplayName,
		Family:            rec.Family,
		Architecture:      rec.Architecture,
		Quantization:      rec.Quantization,
		MaxContextLength:  rec.MaxContextLength,
		MaxOutputLength:   rec.MaxOutputLength,
		MinRAMGB:          rec.MinRAMGB,
		Capabilities:      rec.Capabilities,
		Status:            rec.Status,
		Description:       rec.Description,
		RuntimeParameters: rec.RuntimeParameters,
		Metadata:          rec.Metadata,
	}
}

// normalizeCapabilities trims, drops empties, and de-duplicates a capability
// list while preserving first-seen order.
func normalizeCapabilities(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, c := range in {
		c = strings.TrimSpace(c)
		if c == "" || seen[c] {
			continue
		}
		seen[c] = true
		out = append(out, c)
	}
	return out
}

func (s *Server) writeModelRegistryStoreError(w http.ResponseWriter, operation string, err error) {
	if isModelRegistryNotFound(err) {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
		return
	}
	s.logger.Error("model registry store error", "operation", operation, "error", err)
	writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "model registry store error"))
}

func isModelRegistryNotFound(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(strings.ToLower(err.Error()), "not found")
}

func (s *Server) requirePublishingAPIKey(w http.ResponseWriter, r *http.Request) (publishingActor, bool) {
	provided := strings.TrimSpace(r.Header.Get("X-Darkbloom-Publishing-Key"))
	if provided == "" {
		authz := strings.TrimSpace(r.Header.Get("Authorization"))
		if strings.HasPrefix(strings.ToLower(authz), "bearer ") {
			provided = strings.TrimSpace(authz[len("Bearer "):])
		}
	}
	if provided == "" {
		writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "missing publishing API key"))
		return publishingActor{}, false
	}

	if bootstrap := os.Getenv("MODEL_REGISTRY_PUBLISHING_KEY"); bootstrap != "" && constantTimeStringEqual(provided, bootstrap) {
		return publishingActor{ID: "env-bootstrap", Name: "env-bootstrap"}, true
	}
	// The admin key (EIGENINFERENCE_ADMIN_KEY) is the highest privilege and is
	// also accepted for any publishing/registry action (register, promote,
	// status, runtime-parameters, capabilities).
	if s.adminKey != "" && constantTimeStringEqual(provided, s.adminKey) {
		return publishingActor{ID: "admin", Name: "admin"}, true
	}
	providedHash := publishingSHA256Hex(provided)
	keys, err := s.store.FindPublishingAPIKeysWithError()
	if err != nil {
		s.logger.Error("model registry: failed to find publishing API keys", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to verify publishing API key"))
		return publishingActor{}, false
	}
	for _, key := range keys {
		if !key.Active {
			continue
		}
		if constantTimeStringEqual(providedHash, key.KeyHash) {
			if err := s.store.MarkPublishingAPIKeyUsed(key.ID); err != nil {
				s.logger.Warn("model registry: failed to mark publishing key used", "key_id", key.ID, "error", err)
			}
			return publishingActor{ID: key.ID, Name: key.Name}, true
		}
	}
	writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid publishing API key"))
	return publishingActor{}, false
}

func parseModelCatalogPath(p string) (string, bool) {
	rest := strings.TrimPrefix(p, "/v1/models/catalog/")
	if rest == p || rest == "" {
		return "", false
	}
	modelID, err := url.PathUnescape(rest)
	if err != nil {
		return "", false
	}
	return modelID, true
}

func parseModelCatalogManifestPath(p string) (string, bool) {
	rest := strings.TrimPrefix(p, "/v1/models/catalog/manifest/")
	if rest == p || rest == "" {
		return "", false
	}
	modelID, err := url.PathUnescape(rest)
	if err != nil {
		return "", false
	}
	return modelID, true
}

func parseAdminModelActionPath(p string) (string, string, bool) {
	rest := strings.TrimPrefix(p, "/v1/admin/models/")
	if rest == p || rest == "" {
		return "", "", false
	}
	for _, action := range []string{"/promote", "/status", "/runtime-parameters", "/capabilities", "/deprecation", "/openrouter-slug"} {
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

func validateRegisterModelRequest(req registerModelRequest) error {
	if strings.TrimSpace(req.ModelID) == "" {
		return fmt.Errorf("model_id is required")
	}
	if strings.TrimSpace(req.Version) == "" {
		return fmt.Errorf("version is required")
	}
	if !validRegistryIdentifier(req.ModelID, true) {
		return fmt.Errorf("model_id contains invalid characters or path components")
	}
	if !validRegistryIdentifier(req.Version, false) {
		return fmt.Errorf("version contains invalid characters or path components")
	}
	if strings.TrimSpace(req.Quantization) == "" {
		return fmt.Errorf("quantization is required")
	}
	if req.MaxContextLength <= 0 {
		return fmt.Errorf("max_context_length must be greater than zero")
	}
	if req.MaxOutputLength <= 0 {
		return fmt.Errorf("max_output_length must be greater than zero")
	}
	if req.MinRAMGB <= 0 {
		return fmt.Errorf("min_ram_gb must be greater than zero")
	}
	if req.InputPrice <= 0 {
		return fmt.Errorf("input_price is required and must be positive (micro-USD per 1M tokens)")
	}
	if req.OutputPrice <= 0 {
		return fmt.Errorf("output_price is required and must be positive (micro-USD per 1M tokens)")
	}
	return nil
}

func validateModelManifest(manifest *store.ModelManifest, modelID, version, r2Prefix string) error {
	if manifest == nil {
		return fmt.Errorf("manifest is empty")
	}
	if manifest.SchemaVersion != 1 {
		return fmt.Errorf("unsupported manifest schema_version %d", manifest.SchemaVersion)
	}
	if manifest.ModelID != modelID || manifest.Version != version || manifest.R2Prefix != r2Prefix {
		return fmt.Errorf("manifest fields do not match registration request")
	}
	if !isLowerSHA256Hex(manifest.AggregateSHA256) {
		return fmt.Errorf("manifest aggregate_sha256 must be 64 lowercase hex characters")
	}
	if manifest.TotalSizeBytes < 0 {
		return fmt.Errorf("manifest total_size_bytes must be nonnegative")
	}
	if manifest.FileCount != len(manifest.Files) {
		return fmt.Errorf("manifest file_count does not match files length")
	}
	if len(manifest.Files) == 0 {
		return fmt.Errorf("manifest must contain at least one file")
	}
	var totalSize int64
	seenPaths := make(map[string]bool, len(manifest.Files))
	for _, file := range manifest.Files {
		if err := validateManifestFile(file); err != nil {
			return err
		}
		pathKey := strings.ToLower(file.Path)
		if seenPaths[pathKey] {
			return fmt.Errorf("manifest file path %q is duplicated", file.Path)
		}
		seenPaths[pathKey] = true
		totalSize += file.SizeBytes
	}
	if totalSize != manifest.TotalSizeBytes {
		return fmt.Errorf("manifest total_size_bytes does not match files sum")
	}
	if aggregate := aggregateManifestFileHashes(manifest.Files); aggregate != manifest.AggregateSHA256 {
		return fmt.Errorf("manifest aggregate_sha256 does not match file hashes")
	}
	return nil
}

func aggregateManifestFileHashes(files []store.ManifestFile) string {
	sorted := append([]store.ManifestFile(nil), files...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Path < sorted[j].Path })
	h := sha256.New()
	for _, file := range sorted {
		digest, err := hex.DecodeString(file.SHA256)
		if err != nil || len(digest) != sha256.Size {
			return ""
		}
		h.Write(digest)
	}
	return hex.EncodeToString(h.Sum(nil))
}

func validateManifestFile(file store.ManifestFile) error {
	if !validManifestRelativePath(file.Path) {
		return fmt.Errorf("manifest file path %q is invalid", file.Path)
	}
	if file.SizeBytes < 0 {
		return fmt.Errorf("manifest file %q size_bytes must be nonnegative", file.Path)
	}
	if !isLowerSHA256Hex(file.SHA256) {
		return fmt.Errorf("manifest file %q sha256 must be 64 lowercase hex characters", file.Path)
	}
	return nil
}

func validManifestRelativePath(path string) bool {
	if path == "" || strings.HasPrefix(path, "/") || strings.Contains(path, "\\") {
		return false
	}
	for _, part := range strings.Split(path, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

func containsTraversal(value string) bool {
	return strings.Contains(value, "..")
}

func validRegistryIdentifier(value string, allowSlash bool) bool {
	if value == "" || strings.HasPrefix(value, "/") || containsTraversal(value) {
		return false
	}
	for _, r := range value {
		if r >= '0' && r <= '9' || r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r == '.' || r == '_' || r == '-' {
			continue
		}
		if allowSlash && r == '/' {
			continue
		}
		return false
	}
	return true
}

func isLowerSHA256Hex(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, r := range value {
		if !(r >= '0' && r <= '9') && !(r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}

func fetchModelManifest(ctx context.Context, baseURL, r2Prefix string) (*store.ModelManifest, error) {
	manifestURL, err := url.JoinPath(baseURL, r2Prefix, "manifest.json")
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, manifestURL, nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("manifest GET returned %s", resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 10<<20))
	if err != nil {
		return nil, err
	}
	var manifest store.ModelManifest
	if err := json.Unmarshal(body, &manifest); err != nil {
		return nil, err
	}
	return &manifest, nil
}

func verifyManifestFiles(ctx context.Context, baseURL string, manifest *store.ModelManifest, logger interface{ Warn(string, ...any) }) error {
	client := &http.Client{Timeout: 30 * time.Second}
	errCh := make(chan error, len(manifest.Files))
	fileCh := make(chan store.ManifestFile)
	var wg sync.WaitGroup
	workers := 8
	if len(manifest.Files) < workers {
		workers = len(manifest.Files)
	}
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for file := range fileCh {
				if err := verifyManifestFileHEAD(ctx, client, baseURL, manifest.R2Prefix, file, logger); err != nil {
					errCh <- err
				}
			}
		}()
	}
	for _, file := range manifest.Files {
		select {
		case fileCh <- file:
		case <-ctx.Done():
			close(fileCh)
			wg.Wait()
			close(errCh)
			return ctx.Err()
		}
	}
	close(fileCh)
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			return err
		}
	}
	return nil
}

func verifyManifestFileHEAD(ctx context.Context, client *http.Client, baseURL, r2Prefix string, file store.ManifestFile, logger interface{ Warn(string, ...any) }) error {
	fileURL, err := url.JoinPath(baseURL, r2Prefix, file.Path)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, fileURL, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("HEAD %s: %w", file.Path, err)
	}
	resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HEAD %s returned %s", file.Path, resp.Status)
	}
	if resp.ContentLength >= 0 && resp.ContentLength != file.SizeBytes {
		return fmt.Errorf("HEAD %s content length %d != manifest size %d", file.Path, resp.ContentLength, file.SizeBytes)
	}
	if resp.ContentLength < 0 && logger != nil {
		logger.Warn("model registry: HEAD missing Content-Length", "path", file.Path)
	}
	return nil
}

func catalogModelFromRegistryRecord(rec *store.ModelRegistryRecord) map[string]any {
	supported := supportedModelFromRegistryRecord(rec)
	version := rec.ActiveVersion
	inputModalities, outputModalities := deriveModalities(supported.ModelType, rec.Capabilities)
	model := map[string]any{
		"id":                 supported.ID,
		"s3_name":            supported.S3Name,
		"display_name":       supported.DisplayName,
		"model_type":         supported.ModelType,
		"size_gb":            supported.SizeGB,
		"architecture":       supported.Architecture,
		"description":        supported.Description,
		"min_ram_gb":         supported.MinRAMGB,
		"active":             supported.Active,
		"weight_hash":        supported.WeightHash,
		"family":             rec.Family,
		"quantization":       rec.Quantization,
		"max_context_length": rec.MaxContextLength,
		"max_output_length":  rec.MaxOutputLength,
		"capabilities":       rec.Capabilities,
		"runtime_parameters": rec.RuntimeParameters,
		"metadata":           rec.Metadata,
		"status":             rec.Status,

		// OpenRouter-shaped fields (mirrors /v1/models) for UI consistency.
		"name":                          supported.DisplayName,
		"hugging_face_id":               supported.ID,
		"input_modalities":              inputModalities,
		"output_modalities":             outputModalities,
		"supported_features":            supportedFeaturesFromCapabilities(rec.Capabilities),
		"supported_sampling_parameters": defaultSamplingParameters(),
	}
	if !rec.CreatedAt.IsZero() {
		model["created"] = rec.CreatedAt.Unix()
	}
	if version != nil {
		model["version"] = version.Version
		model["r2_prefix"] = version.R2Prefix
		model["aggregate_sha256"] = version.AggregateSHA256
		model["total_size_bytes"] = version.TotalSizeBytes
		model["file_count"] = version.FileCount
	}
	return model
}

func catalogAliasesForResponse(models []map[string]any, aliases []store.ModelAlias) []map[string]any {
	catalogIDs := make(map[string]struct{}, len(models))
	for _, model := range models {
		id, _ := model["id"].(string)
		if id != "" {
			catalogIDs[id] = struct{}{}
		}
	}
	response := make([]map[string]any, 0, len(aliases))
	for _, alias := range aliases {
		if !alias.Active || alias.DesiredBuild == "" {
			continue
		}
		displayName := alias.DisplayName
		if displayName == "" {
			displayName = alias.AliasID
		}
		retiredBuilds := alias.RetiredBuilds
		if retiredBuilds == nil {
			retiredBuilds = []string{}
		}
		entry := map[string]any{
			"id":             alias.AliasID,
			"display_name":   displayName,
			"desired_build":  alias.DesiredBuild,
			"retired_builds": retiredBuilds,
		}
		if alias.PreviousBuild != "" {
			entry["previous_build"] = alias.PreviousBuild
		}
		if _, ok := catalogIDs[alias.DesiredBuild]; ok {
			entry["primary_build"] = alias.DesiredBuild
		} else if alias.PreviousBuild != "" {
			if _, ok := catalogIDs[alias.PreviousBuild]; ok {
				entry["primary_build"] = alias.PreviousBuild
			}
		}
		if entry["primary_build"] == nil {
			continue
		}
		response = append(response, entry)
	}
	return response
}

func supportedModelFromRegistryRecord(rec *store.ModelRegistryRecord) store.SupportedModel {
	active := rec.Status == "active" || rec.Status == "beta"
	model := store.SupportedModel{
		ID:           rec.ID,
		DisplayName:  rec.DisplayName,
		ModelType:    "text",
		Architecture: rec.Architecture,
		Description:  rec.Description,
		MinRAMGB:     rec.MinRAMGB,
		Active:       active,
	}
	if rec.ActiveVersion != nil {
		model.S3Name = rec.ActiveVersion.R2Prefix
		model.SizeGB = float64(rec.ActiveVersion.TotalSizeBytes) / 1e9
		model.WeightHash = rec.ActiveVersion.AggregateSHA256
		model.Active = active && rec.ActiveVersion.Status == "ready"
	} else {
		model.Active = false
	}
	return model
}

func registryCDNBaseURL() string {
	base := strings.TrimRight(strings.TrimSpace(os.Getenv("MODEL_REGISTRY_CDN_BASE_URL")), "/")
	if base == "" {
		return defaultModelRegistryCDNBaseURL
	}
	return base
}

func modelR2Prefix(modelID, version string) string {
	return "v2/" + readableModelSlug(modelID) + "/" + version
}

func readableModelSlug(modelID string) string {
	var b strings.Builder
	b.Grow(len(modelID) + 14)
	for _, r := range modelID {
		switch {
		case r >= '0' && r <= '9', r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r == '.', r == '_', r == '-':
			b.WriteRune(r)
		case r == '/':
			b.WriteByte('-')
		default:
			b.WriteByte('-')
		}
	}
	slug := strings.Trim(b.String(), "-")
	if slug == "" {
		slug = "model"
	}
	sum := sha256.Sum256([]byte(modelID))
	return slug + "--" + hex.EncodeToString(sum[:])[:12]
}

func publishingSHA256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func constantTimeStringEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func validModelStatus(status string) bool {
	switch status {
	case "beta", "active", "deprecated", "retired":
		return true
	default:
		return false
	}
}
