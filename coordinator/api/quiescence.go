package api

import (
	"encoding/json"
	"net/http"
)

// QuiescenceReport is the Milestone-0 drain inventory used by cutover/rollback.
// Every field must reach zero before releasing coordinator ownership.
type QuiescenceReport struct {
	HTTPInflight        int64 `json:"http_inflight"`
	CompletionInflight  int64 `json:"completion_inflight"`
	ServiceReservations int64 `json:"service_reservations"`
	SettlementHeld      int   `json:"settlement_held"`
	ProviderPending     int   `json:"provider_pending"`
	QueuedRequests      int   `json:"queued_requests"`
	Draining            bool  `json:"draining"`
	Ready               bool  `json:"ready"`
}

func (s *Server) quiescenceReport() QuiescenceReport {
	report := QuiescenceReport{
		HTTPInflight: s.Inflight(),
		Draining:     s.IsDraining(),
	}
	if s.completionWorkers != nil {
		report.CompletionInflight = s.completionWorkers.Inflight()
	}
	if s.serviceReservations != nil {
		report.ServiceReservations = s.serviceReservations.OutstandingTotal()
	}
	if s.settlements != nil {
		report.SettlementHeld = s.settlements.Len()
	}
	if s.registry != nil {
		report.ProviderPending = s.registry.PendingAttemptCount()
		if q := s.registry.Queue(); q != nil {
			report.QueuedRequests = q.TotalSize()
		}
	}
	report.Ready = report.HTTPInflight == 0 &&
		report.CompletionInflight == 0 &&
		report.ServiceReservations == 0 &&
		report.SettlementHeld == 0 &&
		report.ProviderPending == 0 &&
		report.QueuedRequests == 0
	return report
}

// handleAdminQuiescence reports whether the coordinator has drained all mutable
// in-flight work that must be zero before ownership handoff.
func (s *Server) handleAdminQuiescence(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	report := s.quiescenceReport()
	status := http.StatusOK
	if !report.Ready {
		status = http.StatusServiceUnavailable
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(report)
}
