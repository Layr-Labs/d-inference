package access

import (
	"crypto/sha256"
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// AdminKeyAuthorized checks the configured admin bearer credential.
func (s *Owner) AdminKeyAuthorized(token string) bool {
	return s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1
}

// StateExportAuthorized preserves the fixed-length digest comparison used by
// the private-key export endpoint. Interactive admin sessions are not accepted.
func (s *Owner) StateExportAuthorized(token string) bool {
	provided := sha256.Sum256([]byte(token))
	expected := sha256.Sum256([]byte(s.adminKey))
	return s.adminKey != "" && subtle.ConstantTimeCompare(provided[:], expected[:]) == 1
}

// IsAdminAuthorized checks if the request is from an admin.
// Accepts either Privy admin (email in admin list) OR EIGENINFERENCE_ADMIN_KEY.
func (s *Owner) IsAdminAuthorized(w http.ResponseWriter, r *http.Request) bool {
	// Check admin key first (no Privy needed).
	token := ExtractBearerToken(r)
	if token != "" && s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
		return true
	}

	// Check Privy admin.
	user := auth.UserFromContext(r.Context())
	if user != nil && s.IsAdmin(user) {
		return true
	}
	httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("forbidden", "admin access required"))
	return false
}

func (s *Owner) ReleaseKeyAuthorized(token string) bool {
	if s.releaseKey == "" || token == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(s.releaseKey)) == 1
}

// IsAdmin checks if the user has admin privileges (email in admin list).
func (s *Owner) IsAdmin(user *store.User) bool {
	if user == nil || user.Email == "" || len(s.adminEmails) == 0 {
		return false
	}
	return s.adminEmails[strings.ToLower(user.Email)]
}

// RequireAdminKey checks that the request is from an admin (either admin key or Privy admin).
// Returns true if authorized, false if it wrote an error response.
func (s *Owner) RequireAdminKey(w http.ResponseWriter, r *http.Request) bool {
	// Check 1: Bearer token matches admin key
	token := ExtractBearerToken(r)
	if token != "" && s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
		return true
	}

	// Check 2: Privy admin
	user := auth.UserFromContext(r.Context())
	if user != nil && s.IsAdmin(user) {
		return true
	}
	httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("forbidden", "admin access required"))
	return false
}
