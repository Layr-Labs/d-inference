package middleware

import (
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

// middlewareStack keeps the transport-wide middleware order independent of routes.
type Stack struct {
	logger      *slog.Logger
	observation *observation.Owner
	inference   *inference.Owner
	corsOrigin  string
}

func New(logger *slog.Logger, observer *observation.Owner, requests *inference.Owner, corsOrigin string) *Stack {
	return &Stack{logger: logger, observation: observer, inference: requests, corsOrigin: corsOrigin}
}

// Handler applies CORS, outcome recording, recovery, logging, then the body cap.
// Outcome recording must see the recovery write, and recovery must wrap logging.
func (s *Stack) Handler(next http.Handler) http.Handler {
	return s.corsMiddleware(s.observation.ObserveRequestOutcome(s.recoverMiddleware(s.Logging(s.BodyLimit(next))).ServeHTTP))
}
