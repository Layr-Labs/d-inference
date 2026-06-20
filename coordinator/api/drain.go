package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
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
		// Count this request as in-flight BEFORE reading the drain flag. If we
		// checked draining first and incremented second, a request entering in the
		// window between a concurrent SetDraining(true) and its own increment could
		// slip past the gate while /readyz still reported inflight:0 — telling the
		// deploy script it was safe to kill the process mid-request. Incrementing
		// first makes Inflight() (and thus /readyz) a strict upper bound on requests
		// past the gate: any request that observes draining==false was already
		// counted, so it can never be running while /readyz reports 0.
		s.incInflight()
		if s.IsDraining() {
			// Lost the race (or drain was already set): back the count out and
			// reject. A rejected request nets zero change to Inflight().
			s.decInflight()
			s.writeTokenRateLimited(w, "coordinator", "draining", coordinatorDrainRetryAfter)
			return
		}
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

// handleAdminDrain handles POST /v1/admin/drain. It sets the coordinator into
// graceful-drain mode so new inference requests are rejected with 429 while
// in-flight ones finish.
//
// Authorization: the route is wrapped with requireAuth (see routes() in
// server.go) — the SAME pattern used by the other isAdminAuthorized/requireAdminKey
// endpoints (invite codes, credit, reward). requireAuth parses a Privy admin JWT
// into the request context AND accepts EIGENINFERENCE_ADMIN_KEY as a pseudo-account,
// so the isAdminAuthorized check below authorizes EITHER the admin key OR a Privy
// admin. Previously this route was registered raw with no middleware, so
// auth.UserFromContext was never populated and the Privy-admin branch was dead —
// only the admin key worked (the bug this fixes; scripts/admin.sh uses a Privy token).
//
// The body is optional: an empty body (the common case) sets draining=true. An
// explicit JSON body {"draining": false} un-drains, for rolling back an aborted
// upgrade. Returns the resulting drain state and current in-flight count.
func (s *Server) handleAdminDrain(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	// Default to draining=true. Attempt to decode a body whenever one MAY be
	// present — including chunked / unknown-length requests (ContentLength == -1).
	// The previous ContentLength>0 guard silently skipped those and defaulted to
	// draining=true, which broke the {"draining":false} rollback path when sent
	// without a Content-Length (e.g. chunked transfer-encoding). We can't reuse
	// decodeCappedJSON here because it treats an empty body as invalid JSON; an
	// empty body surfaces as io.EOF, which we tolerate as "no override" and keep
	// the draining=true default. The body is still capped for safety.
	draining := true
	if r.Body != nil && r.ContentLength != 0 {
		var payload struct {
			Draining *bool `json:"draining"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxControlPlaneBodyBytes)
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil && !errors.Is(err, io.EOF) {
			var maxErr *http.MaxBytesError
			if errors.As(err, &maxErr) {
				writeJSON(w, http.StatusRequestEntityTooLarge,
					errorResponse("invalid_request_error", "request body too large"))
				return
			}
			writeJSON(w, http.StatusBadRequest,
				errorResponse("invalid_request_error", "invalid JSON"))
			return
		}
		if payload.Draining != nil {
			draining = *payload.Draining
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

// DefaultDrainGrace is how long SIGTERM shutdown waits for in-flight inference
// requests to finish (after entering drain mode) before forcing the HTTP server
// to shut down. Streaming responses can run well past the old 15s Shutdown
// deadline, so the default is generous.
//
// It matches the coordinator's inferenceTimeout (10 minutes): streaming requests
// reset that timeout on each chunk and non-streaming requests may validly take
// the full budget, so a shorter default would still cut healthy generations
// during an otherwise graceful restart. Overridable via EIGENINFERENCE_DRAIN_GRACE.
const DefaultDrainGrace = 600 * time.Second

// drainGracePollInterval is how often WaitForInflightZero re-checks the in-flight
// count while waiting for requests to finish.
const drainGracePollInterval = 100 * time.Millisecond

// DrainGraceFromEnv returns the configured SIGTERM drain grace. It reads
// EIGENINFERENCE_DRAIN_GRACE (a Go duration string, e.g. "90s"); an unset, empty,
// or invalid value falls back to DefaultDrainGrace. An explicit "0" disables the
// wait so shutdown calls http.Server.Shutdown immediately.
func DrainGraceFromEnv() time.Duration {
	raw := strings.TrimSpace(os.Getenv("EIGENINFERENCE_DRAIN_GRACE"))
	if raw == "" {
		return DefaultDrainGrace
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d < 0 {
		return DefaultDrainGrace
	}
	return d
}

// WaitForInflightZero blocks until the in-flight inference count reaches 0 or ctx
// is done (its deadline elapses or it is cancelled), polling periodically. It
// returns true if inflight reached 0 (clean drain) and false if it gave up with
// requests still in flight.
//
// Used by SIGTERM shutdown to let already-admitted (possibly long-streaming)
// requests finish before calling http.Server.Shutdown. It never blocks forever:
// the caller bounds the wait with a context deadline (EIGENINFERENCE_DRAIN_GRACE)
// and then proceeds to Shutdown regardless — Shutdown's own deadline is the hard
// backstop. Pair with SetDraining(true) first so no NEW requests are admitted
// while we wait, otherwise the count may never settle.
func (s *Server) WaitForInflightZero(ctx context.Context) bool {
	if s.Inflight() == 0 {
		return true
	}
	ticker := time.NewTicker(drainGracePollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return s.Inflight() == 0
		case <-ticker.C:
			if s.Inflight() == 0 {
				return true
			}
		}
	}
}
