package accounts

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ListKeys handles GET /v1/keys — lists the caller's keys (masked).
func (s *Controller) ListKeys(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error", "authentication required"))
		return
	}
	keys, err := s.store().ListAPIKeys(user.AccountID)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to list keys"))
		return
	}
	out := make([]types.APIKeyResponse, 0, len(keys))
	for i := range keys {
		out = append(out, s.apiKeyToResponse(&keys[i]))
	}
	httpresponse.WriteJSON(w, http.StatusOK, types.APIKeyListResponse{Object: "list", Data: out})
}

// CreateKey handles POST /v1/keys — mints a new named, optionally
// limited key. The raw secret is returned exactly once.
func (s *Controller) CreateKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error",
			"API key creation requires a Privy account — authenticate with a Privy access token"))
		return
	}

	var req createAPIKeyRequest
	if r.Body != nil {
		// A missing/empty body is allowed (creates a default unnamed key).
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("bad_request", "invalid JSON body"))
			return
		}
	}
	if msg := validateKeyLimitInputs(req.LimitReset, req.LimitUSD, req.RPMLimit, req.ITPMLimit, req.OTPMLimit, req.ExpiresAt); msg != "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("bad_request", msg))
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

	raw, rec, err := s.store().CreateAPIKey(user.AccountID, opts)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to create key"))
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, types.CreateAPIKeyResponse{
		Key:  raw,
		Data: s.apiKeyToResponse(rec),
	})
}

// GetKey handles GET /v1/keys/{id}.
func (s *Controller) GetKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	k, err := s.store().GetAPIKeyByID(user.AccountID, id)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "key not found"))
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, s.apiKeyToResponse(k))
}

// GetCallingKey handles GET /v1/key — returns the metadata for the API
// key used to authenticate the request (OpenRouter parity).
func (s *Controller) GetCallingKey(w http.ResponseWriter, r *http.Request) {
	k := requestcontext.APIKey(r.Context())
	if k == nil || k.ID == "" {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found",
			"no key metadata — this endpoint requires API key authentication"))
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, s.apiKeyToResponse(k))
}

// UpdateKey handles PATCH /v1/keys/{id} — sparse update of a key's
// name, disabled flag, limits, reset window, expiry, and model allow-list.
func (s *Controller) UpdateKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	existing, err := s.store().GetAPIKeyByID(user.AccountID, id)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "key not found"))
		return
	}

	// Decode into a presence map so we can distinguish "field omitted" (leave
	// unchanged) from "field set to null" (clear the limit).
	var patch map[string]json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("bad_request", "invalid JSON body"))
		return
	}
	if msg := applyKeyPatch(existing, patch); msg != "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("bad_request", msg))
		return
	}
	if msg := validateKeyLimitInputs(existing.LimitReset, nil, existing.RPMLimit, existing.ITPMLimit, existing.OTPMLimit, existing.ExpiresAt); msg != "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("bad_request", msg))
		return
	}

	// Bump the auth-cache generation before AND after the mutation so a
	// concurrent request cannot keep authenticating with a stale (e.g.
	// just-disabled) cached record.
	s.keyCache.InvalidateAllKeys()
	updated, err := s.store().UpdateAPIKey(user.AccountID, id, *existing)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to update key"))
		return
	}
	s.keyCache.InvalidateAllKeys()
	httpresponse.WriteJSON(w, http.StatusOK, s.apiKeyToResponse(updated))
}

// DeleteKey handles DELETE /v1/keys/{id} — permanently deletes a key.
func (s *Controller) DeleteKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	s.keyCache.InvalidateAllKeys()
	if err := s.store().RevokeAPIKeyByID(user.AccountID, id); err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "key not found"))
		return
	}
	s.keyCache.InvalidateAllKeys()
	httpresponse.WriteJSON(w, http.StatusOK, types.RevokeKeyResponse{Status: "revoked"})
}

// RotateKey handles POST /v1/keys/{id}/rotate — mints a fresh secret
// carrying the same limits and metadata, then deletes the old key. The new
// secret is returned exactly once.
func (s *Controller) RotateKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	// Bump the auth-cache generation before AND after the mutation so the old
	// secret stops authenticating the instant rotation commits.
	s.keyCache.InvalidateAllKeys()
	raw, rec, err := s.store().RotateAPIKey(user.AccountID, id)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "key not found"))
		return
	}
	s.keyCache.InvalidateAllKeys()
	httpresponse.WriteJSON(w, http.StatusOK, types.CreateAPIKeyResponse{
		Key:  raw,
		Data: s.apiKeyToResponse(rec),
	})
}
