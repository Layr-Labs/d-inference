package api

import (
	"net/http"

	middleware "github.com/eigeninference/d-inference/coordinator/internal/api/middleware"
)

// Handler returns the real router with the transport-wide middleware stack.
func (s *Server) Handler() http.Handler {
	return middleware.New(s.logger, s.observation, s.inference, s.corsOrigin).Handler(s.mux)
}
