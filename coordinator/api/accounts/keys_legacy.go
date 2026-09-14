package accounts

import (
	"encoding/json"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/auth"
)

// CreateLegacyKey handles POST /v1/auth/keys — creates a new consumer API key.
// Requires Privy authentication. The key is linked to the user's account so
// requests made with the key are billed to the same account.
func (s *Controller) CreateLegacyKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error",
			"API key creation requires a Privy account — authenticate with a Privy access token"))
		return
	}

	key, err := s.store().CreateKeyForAccount(user.AccountID)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to create key"))
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, types.CreateKeyResponse{
		APIKey:    key,
		AccountID: user.AccountID,
	})
}

// RevokeLegacyKey handles DELETE /v1/auth/keys — revokes an API key.
// The caller must own the key (same account). Requires Privy auth so a
// compromised API key cannot revoke legitimate keys.
func (s *Controller) RevokeLegacyKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error", "authentication required"))
		return
	}

	var body struct {
		Key string `json:"key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Key == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("bad_request", "provide {\"key\": \"sk-db-...\"}"))
		return
	}

	owner := s.store().GetKeyAccount(body.Key)
	if owner != user.AccountID {
		httpresponse.WriteJSON(w, http.StatusForbidden, httpresponse.ErrorBody("forbidden", "you can only revoke your own keys"))
		return
	}

	if !s.store().RevokeKey(body.Key) {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "key not found or already revoked"))
		return
	}
	s.keyCache.InvalidateKey(body.Key)

	httpresponse.WriteJSON(w, http.StatusOK, types.RevokeKeyResponse{Status: "revoked"})
}
