package access

import (
	"context"
	"crypto/subtle"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// RequireAuth wraps a handler with authentication. It tries Privy JWT first
// (if configured), then falls back to API key validation. The authenticated
// identity is stored in the request context for downstream use.
func (s *Owner) RequireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.setOutcomeStage(r, "auth")
		token := ExtractBearerToken(r)
		if token == "" {
			httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("authentication_error", "missing credentials — use Authorization: Bearer <token>"))
			return
		}

		// Try Privy JWT first (JWTs start with "eyJ").
		if s.privyAuth != nil && strings.HasPrefix(token, "eyJ") {
			privyUserID, err := s.privyAuth.VerifyToken(token)
			if err != nil {
				httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("authentication_error", "invalid Privy token"))
				return
			}
			user, err := s.privyAuth.GetOrCreateUser(privyUserID)
			if err != nil {
				s.logger.Error("privy: user resolution failed", "error", err)
				httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("auth_error", "failed to resolve user"))
				return
			}
			ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
			ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			s.stampAuth(r, "privy", true)
			next(w, r.WithContext(ctx))
			return
		}

		// Accept admin key (admin endpoints handle further authorization in-handler).
		if s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
			ctx := context.WithValue(r.Context(), ctxKeyConsumer, "admin")
			s.stampAuth(r, "admin", false)
			next(w, r.WithContext(ctx))
			return
		}

		// Fall back to API key auth.
		// Check cache first to skip DB on repeat requests with the same key.
		var keyRec *store.APIKey
		authKind := "apikey_cache"
		if cached, ok := s.lookupAPIKeyCache(token); ok {
			keyRec = cached.key
		} else {
			authKind = "apikey_db"
			// Cache miss — resolve the key (with its per-key limits) in one
			// query. A disabled/expired/unknown key returns an error and falls
			// through to the provider-token path below.
			if k, err := s.store.AuthenticateKey(token); err == nil {
				keyRec = k
				// Throttled last-used update: cache misses happen at most once
				// per TTL per active key, so this naturally rate-limits writes.
				if k.ID != "" {
					id := k.ID
					saferun.Go(s.logger, "touch_api_key", func() {
						s.store.TouchAPIKey(id, time.Now())
					})
				}
				// Unlinked legacy key: its identity used to be the raw bearer
				// token; it is now LegacyAccountID(token). Carry any balance from
				// the old raw-token identity to the new one so a pre-existing
				// funded legacy key doesn't suddenly read a zero balance. One-time
				// and a no-op once moved; runs only on a cache miss (≈ once per
				// TTL). The raw token is never logged.
				if k.OwnerAccountID == "" {
					if _, err := s.store.MigrateAccountBalance(token, store.LegacyAccountID(token)); err != nil {
						s.logger.Warn("legacy key balance migration failed", "error", err)
					}
				}
				// Cache the API-key result (positive or negative). Provider-token
				// fallbacks are deliberately NOT cached below.
				s.storeAPIKeyCache(token, apiKeyCacheEntry{key: keyRec, cachedAt: time.Now()})
			} else if pt, err := s.store.GetProviderToken(token); err == nil && pt != nil && pt.Active {
				// Provider device-login tokens authenticate as an account-scoped
				// identity with no per-key limits (ID left empty). These are NOT
				// cached: provider-token revocation has no api-key-cache
				// invalidation hook, so caching would let a revoked token live
				// until TTL. GetProviderToken is cheap and provider-token traffic
				// is low-volume.
				keyRec = &store.APIKey{OwnerAccountID: pt.AccountID}
			} else {
				// Unknown token — negative-cache to avoid hammering the DB.
				s.storeAPIKeyCache(token, apiKeyCacheEntry{key: nil, cachedAt: time.Now()})
			}
		}

		// Re-check time-based expiry / disable on the cache-hit path: a key can
		// expire while a positive entry is still within its TTL, and no mutation
		// event clears the cache on a time-based expiry.
		if keyRec != nil && (keyRec.Disabled || (keyRec.ExpiresAt != nil && time.Now().After(*keyRec.ExpiresAt))) {
			keyRec = nil
		}

		if keyRec == nil {
			httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("authentication_error", "invalid API key"))
			return
		}

		// Resolve key → account. If the key is linked to a Privy account, use
		// that account ID and load the user. Unlinked legacy keys derive a
		// stable, non-secret identity (legacy:<sha256>) instead of using the raw
		// bearer token, so the secret never reaches balances.account_id, ledger
		// references, or logs.
		accountID := keyRec.OwnerAccountID
		ctx := r.Context()
		authDBRead := authKind == "apikey_db"
		if accountID != "" {
			authDBRead = true
			if user, err := s.store.GetUserByAccountID(accountID); err == nil {
				ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			}
		} else {
			accountID = store.LegacyAccountID(token)
		}

		ctx = context.WithValue(ctx, ctxKeyConsumer, accountID)
		ctx = context.WithValue(ctx, ctxKeyAPIKey, keyRec)
		s.stampAuth(r, authKind, authDBRead)
		next(w, r.WithContext(ctx))
	}
}

// RequirePrivyAuth wraps a handler requiring a Privy JWT session. Unlike
// RequireAuth, API keys are rejected. Use for sensitive account operations
// (key creation, device approval) that must not be triggerable by a leaked
// API key.
func (s *Owner) RequirePrivyAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := ExtractBearerToken(r)
		if token == "" {
			httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("authentication_error", "missing credentials"))
			return
		}
		if s.privyAuth == nil || !strings.HasPrefix(token, "eyJ") {
			httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("forbidden",
				"this endpoint requires an interactive session — API keys are not accepted"))
			return
		}
		privyUserID, err := s.privyAuth.VerifyToken(token)
		if err != nil {
			httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("authentication_error", "invalid Privy token"))
			return
		}
		user, err := s.privyAuth.GetOrCreateUser(privyUserID)
		if err != nil {
			s.logger.Error("privy: user resolution failed", "error", err)
			httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("auth_error", "failed to resolve user"))
			return
		}
		ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
		ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
		next(w, r.WithContext(ctx))
	}
}

// ExtractBearerToken extracts the token from "Authorization: Bearer <token>".
func ExtractBearerToken(r *http.Request) string {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		return ""
	}
	parts := strings.SplitN(auth, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
		return ""
	}
	return strings.TrimSpace(parts[1])
}
