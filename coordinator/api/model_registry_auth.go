package api

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"os"
	"strings"
)

type publishingActor struct {
	ID   string
	Name string
}

func (s *Server) requirePublishingAPIKey(w http.ResponseWriter, r *http.Request) (publishingActor, bool) {
	provided := strings.TrimSpace(r.Header.Get("X-Darkbloom-Publishing-Key"))
	if provided == "" {
		provided = extractBearerToken(r)
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
