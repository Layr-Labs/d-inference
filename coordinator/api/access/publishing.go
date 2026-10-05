package access

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

type PublishingActor struct {
	ID   string
	Name string
}

func (s *Owner) RequirePublishingAPIKey(w http.ResponseWriter, r *http.Request) (PublishingActor, bool) {
	provided := strings.TrimSpace(r.Header.Get("X-Darkbloom-Publishing-Key"))
	if provided == "" {
		authz := strings.TrimSpace(r.Header.Get("Authorization"))
		if strings.HasPrefix(strings.ToLower(authz), "bearer ") {
			provided = strings.TrimSpace(authz[len("Bearer "):])
		}
	}
	if provided == "" {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("authentication_error", "missing publishing API key"))
		return PublishingActor{}, false
	}

	if bootstrap := os.Getenv("MODEL_REGISTRY_PUBLISHING_KEY"); bootstrap != "" && constantTimeStringEqual(provided, bootstrap) {
		return PublishingActor{ID: "env-bootstrap", Name: "env-bootstrap"}, true
	}
	// The admin key (EIGENINFERENCE_ADMIN_KEY) is the highest privilege and is
	// also accepted for any publishing/registry action (register, promote,
	// status, runtime-parameters, capabilities).
	if s.AdminKeyAuthorized(provided) {
		return PublishingActor{ID: "admin", Name: "admin"}, true
	}
	providedHash := publishingSHA256Hex(provided)
	keys, err := s.store.FindPublishingAPIKeysWithError()
	if err != nil {
		s.logger.Error("model registry: failed to find publishing API keys", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to verify publishing API key"))
		return PublishingActor{}, false
	}
	for _, key := range keys {
		if !key.Active {
			continue
		}
		if constantTimeStringEqual(providedHash, key.KeyHash) {
			if err := s.store.MarkPublishingAPIKeyUsed(key.ID); err != nil {
				s.logger.Warn("model registry: failed to mark publishing key used", "key_id", key.ID, "error", err)
			}
			return PublishingActor{ID: key.ID, Name: key.Name}, true
		}
	}
	httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("authentication_error", "invalid publishing API key"))
	return PublishingActor{}, false
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
