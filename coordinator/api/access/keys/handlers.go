package keys

// Consumer-facing API key management endpoints and response projections.

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// HandleCreateKey handles POST /v1/auth/keys — creates a new consumer API key.
// Requires Privy authentication. The key is linked to the user's account so
// requests made with the key are billed to the same account.
//
// If every active key on the account is already self_route_only, the minted
// key inherits that ceiling. The console's auto-provision path uses this
// legacy endpoint; minting an unrestricted key here would silently put a
// machine-only account onto the paid public fleet.
func (s *Handler) HandleCreateKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error",
			"API key creation requires a Privy account — authenticate with a Privy access token"))
		return
	}

	keys, err := s.store.ListAPIKeys(user.AccountID)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to create key"))
		return
	}
	raw, _, err := s.store.CreateAPIKey(user.AccountID, store.APIKeyCreate{
		SelfRouteOnly: consoleKeyInheritsSelfRouteOnly(keys, time.Now()),
	})
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to create key"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, types.CreateKeyResponse{
		APIKey:    raw,
		AccountID: user.AccountID,
	})
}

// HandleRevokeKey handles DELETE /v1/auth/keys — revokes an API key.
// The caller must own the key (same account). Requires Privy auth so a
// compromised API key cannot revoke legitimate keys.
func (s *Handler) HandleRevokeKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error", "authentication required"))
		return
	}

	var body struct {
		Key string `json:"key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Key == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("bad_request", "provide {\"key\": \"sk-db-...\"}"))
		return
	}

	owner := s.store.GetKeyAccount(body.Key)
	if owner != user.AccountID {
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("forbidden", "you can only revoke your own keys"))
		return
	}

	if !s.store.RevokeKey(body.Key) {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "key not found or already revoked"))
		return
	}
	s.cache.InvalidateAPIKeyCache(body.Key)
	httpx.WriteJSON(w, http.StatusOK, types.RevokeKeyResponse{Status: "revoked"})
}

// apiKeyToResponse projects a stored key into its masked API representation,
// computing the current-window spend and remaining budget.
func (s *Handler) apiKeyToResponse(k *store.APIKey) types.APIKeyResponse {
	resp := types.APIKeyResponse{
		ID:            k.ID,
		Name:          k.Name,
		Label:         k.Label,
		Disabled:      k.Disabled,
		LimitReset:    store.NormalizeResetWindow(k.LimitReset),
		RPMLimit:      k.RPMLimit,
		ITPMLimit:     k.ITPMLimit,
		OTPMLimit:     k.OTPMLimit,
		AllowedModels: k.AllowedModels,
		SelfRouteOnly: k.SelfRouteOnly,
		ExpiresAt:     k.ExpiresAt,
		CreatedAt:     k.CreatedAt,
		LastUsedAt:    k.LastUsedAt,
	}
	since := store.KeySpendWindowStart(resp.LimitReset, time.Now())
	spent := s.store.KeySpendSince(k.ID, since)
	resp.UsageUSD = microToUSD(spent)
	if k.LimitMicroUSD != nil {
		limitUSD := microToUSD(*k.LimitMicroUSD)
		resp.LimitUSD = &limitUSD
		remaining := *k.LimitMicroUSD - spent
		if remaining < 0 {
			remaining = 0
		}
		remUSD := microToUSD(remaining)
		resp.RemainingUSD = &remUSD
	}
	return resp
}

// HandleListAPIKeys handles GET /v1/keys — lists the caller's keys (masked).
func (s *Handler) HandleListAPIKeys(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error", "authentication required"))
		return
	}
	keys, err := s.store.ListAPIKeys(user.AccountID)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to list keys"))
		return
	}
	out := make([]types.APIKeyResponse, 0, len(keys))
	for i := range keys {
		out = append(out, s.apiKeyToResponse(&keys[i]))
	}
	httpx.WriteJSON(w, http.StatusOK, types.APIKeyListResponse{Object: "list", Data: out})
}

// HandleCreateAPIKey handles POST /v1/keys — mints a new named, optionally
// limited key. The raw secret is returned exactly once.
func (s *Handler) HandleCreateAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error",
			"API key creation requires a Privy account — authenticate with a Privy access token"))
		return
	}

	var req createAPIKeyRequest
	if r.Body != nil {
		// A missing/empty body is allowed (creates a default unnamed key).
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("bad_request", "invalid JSON body"))
			return
		}
	}
	if msg := validateKeyLimitInputs(req.LimitReset, req.LimitUSD, req.RPMLimit, req.ITPMLimit, req.OTPMLimit, req.ExpiresAt); msg != "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("bad_request", msg))
		return
	}

	opts := store.APIKeyCreate{
		Name:          strings.TrimSpace(req.Name),
		LimitReset:    store.NormalizeResetWindow(req.LimitReset),
		RPMLimit:      req.RPMLimit,
		ITPMLimit:     req.ITPMLimit,
		OTPMLimit:     req.OTPMLimit,
		AllowedModels: req.AllowedModels,
		SelfRouteOnly: req.SelfRouteOnly,
		ExpiresAt:     req.ExpiresAt,
	}
	if req.LimitUSD != nil {
		m := usdToMicro(*req.LimitUSD)
		opts.LimitMicroUSD = &m
	}

	raw, rec, err := s.store.CreateAPIKey(user.AccountID, opts)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to create key"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, types.CreateAPIKeyResponse{
		Key:  raw,
		Data: s.apiKeyToResponse(rec),
	})
}

// HandleGetAPIKey handles GET /v1/keys/{id}.
func (s *Handler) HandleGetAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	k, err := s.store.GetAPIKeyByID(user.AccountID, id)
	if err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "key not found"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, s.apiKeyToResponse(k))
}

// HandleGetCallingKey handles GET /v1/key — returns the metadata for the API
// key used to authenticate the request (OpenRouter parity).
func (s *Handler) HandleGetCallingKey(w http.ResponseWriter, r *http.Request) {
	k := access.APIKeyFromContext(r.Context())
	if k == nil || k.ID == "" {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found",
			"no key metadata — this endpoint requires API key authentication"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, s.apiKeyToResponse(k))
}

// HandleUpdateAPIKey handles PATCH /v1/keys/{id} — sparse update of a key's
// name, disabled flag, limits, reset window, expiry, and model allow-list.
func (s *Handler) HandleUpdateAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	existing, err := s.store.GetAPIKeyByID(user.AccountID, id)
	if err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "key not found"))
		return
	}

	// Decode into a presence map so we can distinguish "field omitted" (leave
	// unchanged) from "field set to null" (clear the limit).
	var patch map[string]json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("bad_request", "invalid JSON body"))
		return
	}
	if msg := applyKeyPatch(existing, patch); msg != "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("bad_request", msg))
		return
	}
	if msg := validateKeyLimitInputs(existing.LimitReset, nil, existing.RPMLimit, existing.ITPMLimit, existing.OTPMLimit, existing.ExpiresAt); msg != "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("bad_request", msg))
		return
	}

	// Bump the auth-cache generation before AND after the mutation so a
	// concurrent request cannot keep authenticating with a stale (e.g.
	// just-disabled) cached record.
	s.cache.InvalidateAllAPIKeyCache()
	updated, err := s.store.UpdateAPIKey(user.AccountID, id, *existing)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to update key"))
		return
	}
	s.cache.InvalidateAllAPIKeyCache()
	httpx.WriteJSON(w, http.StatusOK, s.apiKeyToResponse(updated))
}

// HandleDeleteAPIKey handles DELETE /v1/keys/{id} — permanently deletes a key.
func (s *Handler) HandleDeleteAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	s.cache.InvalidateAllAPIKeyCache()
	if err := s.store.RevokeAPIKeyByID(user.AccountID, id); err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "key not found"))
		return
	}
	s.cache.InvalidateAllAPIKeyCache()
	httpx.WriteJSON(w, http.StatusOK, types.RevokeKeyResponse{Status: "revoked"})
}

// HandleRotateAPIKey handles POST /v1/keys/{id}/rotate — mints a fresh secret
// carrying the same limits and metadata, then deletes the old key. The new
// secret is returned exactly once.
func (s *Handler) HandleRotateAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	// Bump the auth-cache generation before AND after the mutation so the old
	// secret stops authenticating the instant rotation commits.
	s.cache.InvalidateAllAPIKeyCache()
	raw, rec, err := s.store.RotateAPIKey(user.AccountID, id)
	if err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "key not found"))
		return
	}
	s.cache.InvalidateAllAPIKeyCache()
	httpx.WriteJSON(w, http.StatusOK, types.CreateAPIKeyResponse{
		Key:  raw,
		Data: s.apiKeyToResponse(rec),
	})
}
