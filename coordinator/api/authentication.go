package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
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

func (s *Server) invalidateAPIKeyCache(token string) { s.requestAuth.InvalidateKey(token) }

// Both sides of a by-ID mutation must invalidate entries from pre-commit state.
func (s *Server) invalidateAllAPIKeyCache() { s.requestAuth.InvalidateAllKeys() }

func extractBearerToken(r *http.Request) string { return requestauth.BearerToken(r) }

func (s *Server) authenticationStore() requestauth.Store { return s.store }
