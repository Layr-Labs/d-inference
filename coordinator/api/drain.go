package api

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/readiness"
)

// readinessController is shared by routes and shutdown, including a directly
// constructed Server. Capabilities resolve current server values when invoked.
func (s *Server) readinessController() *readiness.Controller {
	s.readinessOnce.Do(func() {
		s.readiness = readiness.New(readiness.Dependencies{
			Logger:            func() *slog.Logger { return s.logger },
			AuthorizeAdmin:    s.isAdminAuthorized,
			TrustSafetyStatus: s.trustSafetyStatus,
			WriteRateLimited:  s.inferenceIngress().WriteTokenRateLimited,
			MaxBodyBytes:      maxControlPlaneBodyBytes,
		})
	})
	return s.readiness
}

// SetDraining rejects new inference while already-admitted requests finish.
// Pass false to resume admission. Safe for concurrent use.
func (s *Server) SetDraining(draining bool) { s.readinessController().SetDraining(draining) }

// IsDraining reports whether the coordinator is draining. Safe for concurrent use.
func (s *Server) IsDraining() bool { return s.readinessController().IsDraining() }

// Inflight counts requests inside the inference gate. Safe for concurrent use.
func (s *Server) Inflight() int64 { return s.readinessController().Inflight() }

// WaitForInflightZero waits for admitted requests to finish or the context to end.
// SetDraining(true) before waiting to stop admitting new requests.
func (s *Server) WaitForInflightZero(ctx context.Context) bool {
	return s.readinessController().WaitForInflightZero(ctx)
}

// DefaultDrainGrace is the default wait before SIGTERM proceeds to HTTP shutdown.
const DefaultDrainGrace = readiness.DefaultDrainGrace

// DrainGraceFromEnv reads EIGENINFERENCE_DRAIN_GRACE, including zero to skip waiting.
func DrainGraceFromEnv() time.Duration { return readiness.DrainGraceFromEnv() }
