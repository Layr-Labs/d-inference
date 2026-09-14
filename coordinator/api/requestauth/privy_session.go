package requestauth

import (
	"context"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/auth"
)

// RequirePrivyAuth wraps a handler requiring a Privy JWT session. Unlike
// requireAuth, API keys are rejected. Use for sensitive account operations
// (key creation, device approval) that must not be triggerable by a leaked
// API key.
func (a *Authenticator) RequirePrivyAuth(current func() Settings, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cfg := current()
		token := BearerToken(r)
		if token == "" {
			httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("authentication_error", "missing credentials"))
			return
		}
		if cfg.PrivyAuth == nil || !strings.HasPrefix(token, "eyJ") {
			httpresponse.WriteJSON(w, http.StatusForbidden, httpresponse.ErrorBody("forbidden",
				"this endpoint requires an interactive session — API keys are not accepted"))
			return
		}
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
		next(w, r.WithContext(ctx))
	}
}
