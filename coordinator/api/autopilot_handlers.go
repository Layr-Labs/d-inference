package api

import (
	autopilotapi "github.com/eigeninference/d-inference/coordinator/api/autopilot"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
)

func (s *Server) handleAdminAutopilotInventory(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	httpx.WriteJSON(w, http.StatusOK, s.registry.AutopilotInventory())
}

func (s *Server) handleAdminAutopilot(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}
	ledger, _ := store.As[store.AutopilotStore](s.store)
	autopilotapi.Handler{Controller: s.registry, Ledger: ledger}.ServeHTTP(w, r)
}

func (s *Server) handleAdminAutopilotMachines(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}
	autopilotapi.MachineHandler{Controller: s.registry}.ServeHTTP(w, r)
}

func (s *Server) handleAdminAutopilotRewards(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}
	rewards, _ := store.As[store.AutopilotRewardsStore](s.store)
	handler := autopilotapi.RewardsHandler{Store: rewards, Enabled: s.autopilotRewards != nil}
	if r.Method == http.MethodPatch || r.Method == http.MethodPost {
		s.access.RateLimitFinancial(handler.ServeHTTP)(w, r)
		return
	}
	handler.ServeHTTP(w, r)
}
