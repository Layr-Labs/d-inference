package api

import (
	autopilotapi "github.com/eigeninference/d-inference/coordinator/api/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
)

func (s *Server) handleAdminAutopilot(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}
	ledger, _ := store.As[store.AutopilotStore](s.store)
	autopilotapi.Handler{Controller: s.registry, Ledger: ledger}.ServeHTTP(w, r)
}
