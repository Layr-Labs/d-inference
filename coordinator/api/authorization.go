package api

import (
	"crypto/subtle"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/auth"
)

// requireAdminKey checks that the request is from an admin (either admin key or Privy admin).
// Returns true if authorized, false if it wrote an error response.
func (s *Server) requireAdminKey(w http.ResponseWriter, r *http.Request) bool {
	// Check 1: Bearer token matches admin key
	token := extractBearerToken(r)
	if token != "" && s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
		return true
	}

	// Check 2: Privy admin
	user := auth.UserFromContext(r.Context())
	if user != nil && s.isAdmin(user) {
		return true
	}

	writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
	return false
}
