package api

import (
	"net/http"
	"time"
)

// Graceful coordinator drain (DAR-327 Phase 1, zero-downtime upgrades).
//
// Before a restart or binary swap the coordinator is put into drain mode via
// POST /v1/admin/drain. While draining:
//   - the drain gate rejects NEW inference requests with 429 + Retry-After so
//     clients (and OpenRouter-style routers) retry against a ready coordinator;
//   - already-admitted in-flight requests run to completion;
//   - GET /readyz reports not-ready (503) so load balancers stop sending traffic
//     and the deploy script can poll until inflight reaches 0 before shutting the
//     process down.
//
// This is purely the coordinator's own HTTP-ingress drain and is intentionally
// distinct from the provider-side drain concepts (protocol.ProviderDrainingForUpdate,
// registry.drainQueuedRequestsForModels). The state lives on the Server struct
// (httpInflight atomic.Int64, coordinatorDraining atomic.Bool — see server.go).

// coordinatorDrainRetryAfter is the Retry-After advertised to inference requests
// rejected by the drain gate. Kept small so well-behaved clients retry quickly
// against the next ready coordinator instead of failing hard.
const coordinatorDrainRetryAfter = 3 * time.Second

// SetDraining toggles the coordinator's graceful-drain state. When true the
// drain gate rejects new inference requests (429 + Retry-After) while in-flight
// requests finish, and /readyz reports not-ready. Pass false to un-drain (e.g.
// to roll back an aborted upgrade). Safe for concurrent use.
func (s *Server) SetDraining(draining bool) {
	s.coordinatorDraining.Store(draining)
}

// IsDraining reports whether the coordinator is currently draining for a
// restart/upgrade. Safe for concurrent use.
func (s *Server) IsDraining() bool {
	return s.coordinatorDraining.Load()
}

// Inflight returns the number of inference requests currently being served
// through the drain gate. Safe for concurrent use.
func (s *Server) Inflight() int64 {
	return s.httpInflight.Load()
}

// incInflight records the entry of an inference request into the drain gate and
// returns the new in-flight count.
func (s *Server) incInflight() int64 {
	return s.httpInflight.Add(1)
}

// decInflight records the exit of an inference request from the drain gate and
// returns the new in-flight count.
func (s *Server) decInflight() int64 {
	return s.httpInflight.Add(-1)
}

// drainGate wraps an inference handler with the coordinator's graceful-drain
// gate. Mirrors the sealedTransport wrapper shape (func(http.HandlerFunc)
// http.HandlerFunc) and is applied as the OUTERMOST wrapper on the inference
// routes so it short-circuits before any auth/decrypt work.
//
// While draining it rejects the request with 429 + Retry-After (reusing
// writeTokenRateLimited so the body/headers match the coordinator's other 429s).
// Otherwise it counts the request as in-flight for the lifetime of the handler
// so /readyz and the deploy script can wait for inflight==0 before shutdown.
//
// Once draining is set, every new request observes it and is rejected, so the
// in-flight count only decreases and, combined with http.Server.Shutdown's own
// connection draining, reaches a stable 0.
func (s *Server) drainGate(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.IsDraining() {
			s.writeTokenRateLimited(w, "coordinator", "draining", coordinatorDrainRetryAfter)
			return
		}
		s.incInflight()
		defer s.decInflight()
		next(w, r)
	}
}

// handleReadyz handles GET /readyz (unauthenticated). It reports the
// coordinator's drain/readiness state so load balancers and the deploy script
// treat a draining coordinator as not-ready and can wait for inflight==0 before
// restarting. Returns 200 while ready and 503 while draining. Modeled on
// handleHealth, but health is liveness ("process is up") while this is readiness
// ("safe to route new traffic here").
func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	draining := s.IsDraining()
	status := http.StatusOK
	if draining {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, readinessResponse{
		Draining: draining,
		Inflight: s.Inflight(),
		Ready:    !draining,
	})
}

// readinessResponse is the JSON body returned by GET /readyz.
type readinessResponse struct {
	Draining bool  `json:"draining"`
	Inflight int64 `json:"inflight"`
	Ready    bool  `json:"ready"`
}

// handleAdminDrain handles POST /v1/admin/drain (admin-gated, registered raw
// like /v1/admin/metrics). It sets the coordinator into graceful-drain mode so
// new inference requests are rejected with 429 while in-flight ones finish.
//
// The body is optional: an empty body (the common case) sets draining=true. An
// explicit JSON body {"draining": false} un-drains, for rolling back an aborted
// upgrade. Returns the resulting drain state and current in-flight count.
func (s *Server) handleAdminDrain(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	// Default to draining=true; only parse a body when one is actually present
	// (decodeCappedJSON treats an empty body as invalid JSON).
	draining := true
	if r.ContentLength > 0 {
		var req struct {
			Draining *bool `json:"draining"`
		}
		if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
			return
		}
		if req.Draining != nil {
			draining = *req.Draining
		}
	}

	s.SetDraining(draining)
	s.logger.Info("coordinator drain state changed",
		"draining", draining,
		"inflight", s.Inflight(),
	)
	writeJSON(w, http.StatusOK, map[string]any{
		"draining": draining,
		"inflight": s.Inflight(),
	})
}
