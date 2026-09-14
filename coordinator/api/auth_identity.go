package api

import (
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// resolveAccountID returns the internal account ID for the current request.
// Prefers the Privy user's account ID, falls back to API key.
func (s *Server) resolveAccountID(r *http.Request) string { return requestauth.ResolveAccountID(r) }

// isAdmin checks if the user has admin privileges (email in admin list).
func (s *Server) isAdmin(user *store.User) bool {
	if user == nil || user.Email == "" || len(s.adminEmails) == 0 {
		return false
	}
	return s.adminEmails[strings.ToLower(user.Email)]
}

// requirePrivyUser requires a linked user installed by authentication middleware.
// Interactive-session-only routes still enforce their own API-key exclusion.
// Returns the user or writes a 401 error and returns nil.
func (s *Server) requirePrivyUser(w http.ResponseWriter, r *http.Request) *store.User {
	return requestauth.RequirePrivyUser(w, r)
}
