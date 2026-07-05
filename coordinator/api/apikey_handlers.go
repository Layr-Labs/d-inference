package api

// apikey_handlers.go holds the consumer-facing API key management endpoints
// (create/list/get/update/rotate/delete) plus their request validation and
// response-shaping helpers. Split out of consumer.go to keep key management
// separate from the inference request path.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// handleCreateKey handles POST /v1/auth/keys — creates a new consumer API key.
// Requires Privy authentication. The key is linked to the user's account so
// requests made with the key are billed to the same account.
func (s *Server) handleCreateKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error",
			"API key creation requires a Privy account — authenticate with a Privy access token"))
		return
	}

	key, err := s.store.CreateKeyForAccount(user.AccountID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create key"))
		return
	}
	writeJSON(w, http.StatusOK, types.CreateKeyResponse{
		APIKey:    key,
		AccountID: user.AccountID,
	})
}

// handleRevokeKey handles DELETE /v1/auth/keys — revokes an API key.
// The caller must own the key (same account). Requires Privy auth so a
// compromised API key cannot revoke legitimate keys.
func (s *Server) handleRevokeKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}

	var body struct {
		Key string `json:"key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Key == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", "provide {\"key\": \"sk-db-...\"}"))
		return
	}

	owner := s.store.GetKeyAccount(body.Key)
	if owner != user.AccountID {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "you can only revoke your own keys"))
		return
	}

	if !s.store.RevokeKey(body.Key) {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found or already revoked"))
		return
	}
	s.invalidateAPIKeyCache(body.Key)

	writeJSON(w, http.StatusOK, types.RevokeKeyResponse{Status: "revoked"})
}

// apiKeyToResponse projects a stored key into its masked API representation,
// computing the current-window spend and remaining budget.
func (s *Server) apiKeyToResponse(k *store.APIKey) types.APIKeyResponse {
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

// validateKeyLimitInputs sanity-checks user-supplied limit values. Returns a
// human-readable error string (empty when valid).
func validateKeyLimitInputs(reset string, limitUSD *float64, rpm, itpm, otpm *int64, expiresAt *time.Time) string {
	switch reset {
	case "", store.KeyResetNone, store.KeyResetDaily, store.KeyResetWeekly, store.KeyResetMonthly:
	default:
		return "limit_reset must be one of: none, daily, weekly, monthly"
	}
	if limitUSD != nil && *limitUSD < 0 {
		return "limit_usd must be >= 0"
	}
	if rpm != nil && *rpm < 0 {
		return "rpm_limit must be >= 0"
	}
	if itpm != nil && *itpm < 0 {
		return "itpm_limit must be >= 0"
	}
	if otpm != nil && *otpm < 0 {
		return "otpm_limit must be >= 0"
	}
	if expiresAt != nil && !expiresAt.IsZero() && expiresAt.Before(time.Now()) {
		return "expires_at must be in the future"
	}
	return ""
}

// keyModelAllowed returns false when the calling key restricts models via an
// allow-list that does not include the requested model. Account-scoped/legacy
// keys (no key in context) and keys without an allow-list always pass.
func (s *Server) keyModelAllowed(ctx context.Context, model string) bool {
	k := apiKeyFromContext(ctx)
	if k == nil || len(k.AllowedModels) == 0 {
		return true
	}
	for _, m := range k.AllowedModels {
		if m == model {
			return true
		}
	}
	return false
}

// checkKeySpendCap reports whether charging additionalMicroUSD to the calling
// key would exceed its per-key spend cap in the current window. It returns
// (message, ok); ok=false means the request must be rejected with 402. The
// per-account balance ledger is still the hard atomic ceiling — this is the
// soft, per-key sub-cap, enforced against settled usage (so concurrent
// in-flight requests are eventually-consistent, never over the account balance).
func (s *Server) checkKeySpendCap(ctx context.Context, additionalMicroUSD int64) (string, bool) {
	k := apiKeyFromContext(ctx)
	if k == nil || k.ID == "" || k.LimitMicroUSD == nil {
		return "", true
	}
	since := store.KeySpendWindowStart(k.LimitReset, time.Now())
	spent := s.store.KeySpendSince(k.ID, since)
	if spent+additionalMicroUSD > *k.LimitMicroUSD {
		window := store.NormalizeResetWindow(k.LimitReset)
		if window == store.KeyResetNone {
			window = "total"
		}
		return fmt.Sprintf("API key spend limit reached (%s cap $%.2f, used $%.2f) — raise this key's limit or use another key",
			window, microToUSD(*k.LimitMicroUSD), microToUSD(spent)), false
	}
	return "", true
}

// handleListAPIKeys handles GET /v1/keys — lists the caller's keys (masked).
func (s *Server) handleListAPIKeys(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	keys, err := s.store.ListAPIKeys(user.AccountID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to list keys"))
		return
	}
	out := make([]types.APIKeyResponse, 0, len(keys))
	for i := range keys {
		out = append(out, s.apiKeyToResponse(&keys[i]))
	}
	writeJSON(w, http.StatusOK, types.APIKeyListResponse{Object: "list", Data: out})
}

// handleCreateAPIKey handles POST /v1/keys — mints a new named, optionally
// limited key. The raw secret is returned exactly once.
func (s *Server) handleCreateAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error",
			"API key creation requires a Privy account — authenticate with a Privy access token"))
		return
	}

	var req createAPIKeyRequest
	if r.Body != nil {
		// A missing/empty body is allowed (creates a default unnamed key).
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", "invalid JSON body"))
			return
		}
	}
	if msg := validateKeyLimitInputs(req.LimitReset, req.LimitUSD, req.RPMLimit, req.ITPMLimit, req.OTPMLimit, req.ExpiresAt); msg != "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", msg))
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
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create key"))
		return
	}
	writeJSON(w, http.StatusOK, types.CreateAPIKeyResponse{
		Key:  raw,
		Data: s.apiKeyToResponse(rec),
	})
}

// handleGetAPIKey handles GET /v1/keys/{id}.
func (s *Server) handleGetAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	k, err := s.store.GetAPIKeyByID(user.AccountID, id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found"))
		return
	}
	writeJSON(w, http.StatusOK, s.apiKeyToResponse(k))
}

// handleGetCallingKey handles GET /v1/key — returns the metadata for the API
// key used to authenticate the request (OpenRouter parity).
func (s *Server) handleGetCallingKey(w http.ResponseWriter, r *http.Request) {
	k := apiKeyFromContext(r.Context())
	if k == nil || k.ID == "" {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found",
			"no key metadata — this endpoint requires API key authentication"))
		return
	}
	writeJSON(w, http.StatusOK, s.apiKeyToResponse(k))
}

// handleUpdateAPIKey handles PATCH /v1/keys/{id} — sparse update of a key's
// name, disabled flag, limits, reset window, expiry, and model allow-list.
func (s *Server) handleUpdateAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	existing, err := s.store.GetAPIKeyByID(user.AccountID, id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found"))
		return
	}

	// Decode into a presence map so we can distinguish "field omitted" (leave
	// unchanged) from "field set to null" (clear the limit).
	var patch map[string]json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", "invalid JSON body"))
		return
	}
	if msg := applyKeyPatch(existing, patch); msg != "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", msg))
		return
	}
	if msg := validateKeyLimitInputs(existing.LimitReset, nil, existing.RPMLimit, existing.ITPMLimit, existing.OTPMLimit, existing.ExpiresAt); msg != "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", msg))
		return
	}

	// Bump the auth-cache generation before AND after the mutation so a
	// concurrent request cannot keep authenticating with a stale (e.g.
	// just-disabled) cached record.
	s.invalidateAllAPIKeyCache()
	updated, err := s.store.UpdateAPIKey(user.AccountID, id, *existing)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to update key"))
		return
	}
	s.invalidateAllAPIKeyCache()
	writeJSON(w, http.StatusOK, s.apiKeyToResponse(updated))
}

// applyKeyPatch merges a presence-aware PATCH body into an existing key record.
// Returns a human-readable error string on invalid input (empty when ok).
func applyKeyPatch(k *store.APIKey, patch map[string]json.RawMessage) string {
	if raw, ok := patch["name"]; ok {
		var name string
		if err := json.Unmarshal(raw, &name); err != nil {
			return "invalid value for name"
		}
		k.Name = strings.TrimSpace(name)
	}
	if raw, ok := patch["disabled"]; ok {
		var disabled bool
		if err := json.Unmarshal(raw, &disabled); err != nil {
			return "invalid value for disabled"
		}
		k.Disabled = disabled
	}
	if raw, ok := patch["limit_reset"]; ok {
		var reset string
		if err := json.Unmarshal(raw, &reset); err != nil {
			return "invalid value for limit_reset"
		}
		k.LimitReset = store.NormalizeResetWindow(reset)
	}
	if raw, ok := patch["limit_usd"]; ok {
		if string(raw) == "null" {
			k.LimitMicroUSD = nil
		} else {
			var usd float64
			if err := json.Unmarshal(raw, &usd); err != nil {
				return "invalid value for limit_usd"
			}
			if usd < 0 {
				return "limit_usd must be >= 0"
			}
			m := usdToMicro(usd)
			k.LimitMicroUSD = &m
		}
	}
	if raw, ok := patch["allowed_models"]; ok {
		if string(raw) == "null" {
			k.AllowedModels = nil
		} else {
			var models []string
			if err := json.Unmarshal(raw, &models); err != nil {
				return "invalid value for allowed_models"
			}
			k.AllowedModels = models
		}
	}
	if raw, ok := patch["self_route_only"]; ok {
		var v bool
		if err := json.Unmarshal(raw, &v); err != nil {
			return "invalid value for self_route_only"
		}
		k.SelfRouteOnly = v
	}
	for field, dst := range map[string]**int64{
		"rpm_limit":  &k.RPMLimit,
		"itpm_limit": &k.ITPMLimit,
		"otpm_limit": &k.OTPMLimit,
	} {
		if raw, ok := patch[field]; ok {
			if string(raw) == "null" {
				*dst = nil
			} else {
				var v int64
				if err := json.Unmarshal(raw, &v); err != nil {
					return "invalid value for " + field
				}
				*dst = &v
			}
		}
	}
	if raw, ok := patch["expires_at"]; ok {
		if string(raw) == "null" {
			k.ExpiresAt = nil
		} else {
			var t time.Time
			if err := json.Unmarshal(raw, &t); err != nil {
				return "invalid value for expires_at (use RFC 3339)"
			}
			k.ExpiresAt = &t
		}
	}
	return ""
}

// handleDeleteAPIKey handles DELETE /v1/keys/{id} — permanently deletes a key.
func (s *Server) handleDeleteAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	s.invalidateAllAPIKeyCache()
	if err := s.store.RevokeAPIKeyByID(user.AccountID, id); err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found"))
		return
	}
	s.invalidateAllAPIKeyCache()
	writeJSON(w, http.StatusOK, types.RevokeKeyResponse{Status: "revoked"})
}

// handleRotateAPIKey handles POST /v1/keys/{id}/rotate — mints a fresh secret
// carrying the same limits and metadata, then deletes the old key. The new
// secret is returned exactly once.
func (s *Server) handleRotateAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	// Bump the auth-cache generation before AND after the mutation so the old
	// secret stops authenticating the instant rotation commits.
	s.invalidateAllAPIKeyCache()
	raw, rec, err := s.store.RotateAPIKey(user.AccountID, id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found"))
		return
	}
	s.invalidateAllAPIKeyCache()
	writeJSON(w, http.StatusOK, types.CreateAPIKeyResponse{
		Key:  raw,
		Data: s.apiKeyToResponse(rec),
	})
}
