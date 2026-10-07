package access

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ResolveAccountID prefers the Privy account and otherwise uses the API-key identity.
func ResolveAccountID(r *http.Request) string {
	if user := auth.UserFromContext(r.Context()); user != nil {
		return user.AccountID
	}
	return ConsumerKeyFromContext(r.Context())
}

// RequirePrivyUser rejects API-key-only requests to account-management endpoints.
func RequirePrivyUser(w http.ResponseWriter, r *http.Request) *store.User {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error",
			"this endpoint requires a Privy account — authenticate with a Privy access token"))
		return nil
	}
	return user
}
