package api

import (
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// resolveAccountID returns the internal account ID for the current request.
// Prefers the Privy user's account ID, falls back to API key.
func (s *Server) resolveAccountID(r *http.Request) string {
	if user := auth.UserFromContext(r.Context()); user != nil {
		return user.AccountID
	}
	return consumerKeyFromContext(r.Context())
}

// isAdmin checks if the user has admin privileges (email in admin list).
func (s *Server) isAdmin(user *store.User) bool {
	if user == nil || user.Email == "" || len(s.adminEmails) == 0 {
		return false
	}
	return s.adminEmails[strings.ToLower(user.Email)]
}

// requirePrivyUser checks that the request is authenticated via Privy (not just API key).
// Returns the user or writes a 401 error and returns nil.
func (s *Server) requirePrivyUser(w http.ResponseWriter, r *http.Request) *store.User {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error",
			"this endpoint requires a Privy account — authenticate with a Privy access token"))
		return nil
	}
	return user
}
