package api

import (
	"net/http"
	"net/url"
	"os"
	"strings"
)

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
