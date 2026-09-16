// Package requestauth resolves identities already installed by authentication
// middleware and applies shared endpoint user-context requirements.
package requestauth

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ResolveAccountID returns the internal account ID for the current request.
// Prefers the Privy user's account ID, falls back to API key.
func ResolveAccountID(r *http.Request) string {
	if user := auth.UserFromContext(r.Context()); user != nil {
		return user.AccountID
	}
	return requestcontext.AccountID(r.Context())
}

// RequirePrivyUser requires a linked user in the authenticated request context.
// Interactive-session-only routes must still reject API keys in middleware.
// Returns the user or writes a 401 error and returns nil.
func RequirePrivyUser(w http.ResponseWriter, r *http.Request) *store.User {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error",
			"this endpoint requires a Privy account — authenticate with a Privy access token"))
		return nil
	}
	return user
}
