package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// handleHealth handles GET /health.
// Returns the coordinator's status and the number of connected providers.
// This endpoint does not require authentication.
//
// /health is a LIVENESS probe: it returns 200 whenever the process is up, INCLUDING
// while draining. This is deliberate. The production host Caddy health-checks its
// single coordinator upstream on /health with health_status 200, so returning 503 here
// would mark the only backend down and make the admin/rollback endpoints
// (POST /v1/admin/drain {"draining":false}) and /readyz unreachable through the
// public URL — you could not undo a drain remotely. Drain/readiness lives on
// /readyz (readiness.Controller.Ready, 503 while draining), which the deploy script and
// multi-backend load balancers consult to shift traffic. The body still reports
// draining=true for observability, but the status code stays 200.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, types.HealthResponse{
		Status:      "ok",
		Draining:    s.IsDraining(),
		Providers:   s.registry.ProviderCount(),
		Version:     BuildVersion,
		BuildCommit: BuildCommit,
		BuildDate:   BuildDate,
	})
}
