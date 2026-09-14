package readiness

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// readinessResponse is the JSON body returned by GET /readyz.
type readinessResponse struct {
	Draining     bool   `json:"draining"`
	Inflight     int64  `json:"inflight"`
	Ready        bool   `json:"ready"`
	HealthReason string `json:"health_reason,omitempty"`
}

// Ready serves the unauthenticated readiness probe. Draining or blocked trust
// safety returns 503. The API's separate health endpoint remains a liveness probe.
func (s *Controller) Ready(w http.ResponseWriter, r *http.Request) {
	draining := s.IsDraining()
	trustSafetyBlocked, healthReason := s.deps.TrustSafetyStatus()
	ready := !draining && !trustSafetyBlocked
	status := http.StatusOK
	if !ready {
		status = http.StatusServiceUnavailable
	}
	httpresponse.WriteJSON(w, status, readinessResponse{
		Draining:     draining,
		Inflight:     s.Inflight(),
		Ready:        ready,
		HealthReason: healthReason,
	})
}
