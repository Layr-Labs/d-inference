package requestauth

import (
	"context"
	"crypto/subtle"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// RequireAuth wraps a handler with authentication. It tries Privy JWT first
// (if configured), then the admin key, API keys, and active provider tokens. The authenticated
// identity is stored in the request context for downstream use.
func (a *Authenticator) RequireAuth(current func() Settings, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cfg := current()
		cfg.SetStage(r, "auth")
		token := BearerToken(r)
		if token == "" {
			httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("authentication_error", "missing credentials — use Authorization: Bearer <token>"))
			return
		}

		// Try Privy JWT first (JWTs start with "eyJ").
		if cfg.PrivyAuth != nil && strings.HasPrefix(token, "eyJ") {
			privyUserID, err := cfg.PrivyAuth.VerifyToken(token)
			if err != nil {
				httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("authentication_error", "invalid Privy token"))
				return
			}
			user, err := cfg.PrivyAuth.GetOrCreateUser(privyUserID)
			if err != nil {
				cfg.Logger.Error("privy: user resolution failed", "error", err)
				httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("auth_error", "failed to resolve user"))
				return
			}
			ctx := requestcontext.WithAccountID(r.Context(), user.AccountID)
			ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			cfg.StampAuth(r, "privy", true)
			next(w, r.WithContext(ctx))
			return
		}

		// Accept admin key (admin endpoints handle further authorization in-handler).
		if cfg.AdminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(cfg.AdminKey)) == 1 {
			ctx := requestcontext.WithAccountID(r.Context(), "admin")
			cfg.StampAuth(r, "admin", false)
			next(w, r.WithContext(ctx))
			return
		}

		// Fall back to API key auth.
		// Check cache first to skip DB on repeat requests with the same key.
		var keyRec *store.APIKey
		authKind := "apikey_cache"
		if cached, generation, ok := a.keys.lookup(token); ok {
			keyRec = cached.key
		} else {
			authKind = "apikey_db"
			// Cache miss — resolve the key (with its per-key limits) in one
			// query. A disabled/expired/unknown key returns an error and falls
			// through to the provider-token path below.
			if k, err := cfg.Store().AuthenticateKey(token); err == nil {
				keyRec = k
				// Throttled last-used update: cache misses happen at most once
				// per TTL per active key, so this naturally rate-limits writes.
				if k.ID != "" {
					id := k.ID
					saferun.Go(cfg.Logger, "touch_api_key", func() {
						cfg.Store().TouchAPIKey(id, time.Now())
					})
				}
				// Unlinked legacy key: its identity used to be the raw bearer
				// token; it is now LegacyAccountID(token). Carry any balance from
				// the old raw-token identity to the new one so a pre-existing
				// funded legacy key doesn't suddenly read a zero balance. One-time
				// and a no-op once moved; runs only on a cache miss (≈ once per
				// TTL). The raw token is never logged.
				if k.OwnerAccountID == "" {
					if _, err := cfg.Store().MigrateAccountBalance(token, store.LegacyAccountID(token)); err != nil {
						cfg.Logger.Warn("legacy key balance migration failed", "error", err)
					}
				}
				// Cache the API-key result (positive or negative). Provider-token
				// fallbacks are deliberately NOT cached below.
				a.keys.store(token, keyEntry{key: keyRec, cachedAt: time.Now(), gen: generation})
			} else if pt, err := cfg.Store().GetProviderToken(token); err == nil && pt != nil && pt.Active {
				// Provider device-login tokens authenticate as an account-scoped
				// identity with no per-key limits (ID left empty). These are NOT
				// cached: provider-token revocation has no api-key-cache
				// invalidation hook, so caching would let a revoked token live
				// until TTL. GetProviderToken is cheap and provider-token traffic
				// is low-volume.
				keyRec = &store.APIKey{OwnerAccountID: pt.AccountID}
			} else {
				// Unknown token — negative-cache to avoid hammering the DB.
				a.keys.store(token, keyEntry{key: nil, cachedAt: time.Now(), gen: generation})
			}
		}

		// Re-check time-based expiry / disable on the cache-hit path: a key can
		// expire while a positive entry is still within its TTL, and no mutation
		// event clears the cache on a time-based expiry.
		if keyRec != nil && (keyRec.Disabled || (keyRec.ExpiresAt != nil && time.Now().After(*keyRec.ExpiresAt))) {
			keyRec = nil
		}

		if keyRec == nil {
			httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("authentication_error", "invalid API key"))
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
			if user, err := cfg.Store().GetUserByAccountID(accountID); err == nil {
				ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			}
		} else {
			accountID = store.LegacyAccountID(token)
		}

		ctx = requestcontext.WithAccountID(ctx, accountID)
		ctx = requestcontext.WithAPIKey(ctx, keyRec)
		cfg.StampAuth(r, authKind, authDBRead)
		next(w, r.WithContext(ctx))
	}
}
