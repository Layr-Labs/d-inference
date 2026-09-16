package api

import (
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
	"github.com/eigeninference/d-inference/coordinator/auth"
)

// authenticationSettings reads current configuration after route registration.
// The shared authenticator owns the key cache; Server retains service wiring and
// the existing request accounting/profiling hooks.
func (s *Server) authenticationSettings() requestauth.Settings {
	return requestauth.Settings{
		Store: s.authenticationStore, Logger: s.logger, PrivyAuth: s.privyAuth, AdminKey: s.adminKey,
		SetStage: setOutcomeStage, StampAuth: stampAuth,
	}
}

func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return s.requestAuth.RequireAuth(s.authenticationSettings, next)
}

func (s *Server) requirePrivyAuth(next http.HandlerFunc) http.HandlerFunc {
	return s.requestAuth.RequirePrivyAuth(s.authenticationSettings, next)
}

func extractBearerToken(r *http.Request) string { return requestauth.BearerToken(r) }

func (s *Server) authenticationStore() requestauth.Store { return s.store }

// SetAdminKey configures the admin API key for admin-only endpoints.
func (s *Server) SetAdminKey(key string) {
	s.adminKey = key
}

// SetPrivyAuth configures Privy JWT authentication for consumer endpoints.
func (s *Server) SetPrivyAuth(pa *auth.PrivyAuth) {
	s.privyAuth = pa
}

// SetAdminEmails configures which Privy accounts have admin access.
func (s *Server) SetAdminEmails(emails []string) {
	s.adminEmails = make(map[string]bool, len(emails))
	for _, e := range emails {
		s.adminEmails[strings.ToLower(strings.TrimSpace(e))] = true
	}
}
