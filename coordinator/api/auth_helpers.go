package api

// Shared authentication/authorization gates used across the api handlers:
// resolving the caller's account, admin checks (admin key or Privy admin),
// and the Privy-user requirement.

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

// adminKeyMatches reports whether token is a non-empty match for the configured
// admin key, using a length-guarded constant-time compare. Both the token and
// the configured key must be non-empty (an empty admin key never matches).
func (s *Server) adminKeyMatches(token string) bool {
	return token != "" && s.adminKey != "" && constantTimeStringEqual(token, s.adminKey)
}

// isAdminAuthorized checks if the request is from an admin.
// Accepts either Privy admin (email in admin list) OR EIGENINFERENCE_ADMIN_KEY.
func (s *Server) isAdminAuthorized(w http.ResponseWriter, r *http.Request) bool {
	// Check admin key first (no Privy needed).
	if s.adminKeyMatches(extractBearerToken(r)) {
		return true
	}

	// Check Privy admin.
	user := auth.UserFromContext(r.Context())
	if user != nil && s.isAdmin(user) {
		return true
	}

	writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
	return false
}

// requirePrivyUser checks that the request is authenticated via Privy (not just
// an API key). Returns the user, or writes a 401 and returns nil. An optional
// message overrides the default 401 body so callers can keep their own wording.
func (s *Server) requirePrivyUser(w http.ResponseWriter, r *http.Request, msg ...string) *store.User {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		m := "this endpoint requires a Privy account — authenticate with a Privy access token"
		if len(msg) > 0 && msg[0] != "" {
			m = msg[0]
		}
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", m))
		return nil
	}
	return user
}
