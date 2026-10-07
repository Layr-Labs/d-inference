package api

import "context"

// Application-facing lifecycle entrypoints delegate to the observation owner.
func (s *Server) StartProfilerLoops(ctx context.Context) { s.observation.StartProfilerLoops(ctx) }
func (s *Server) SampleFleetNow()                        { s.observation.SampleFleetNow() }
func (s *Server) PruneTelemetryNow(ctx context.Context)  { s.observation.PruneTelemetryNow(ctx) }
func (s *Server) StartDDGaugeLoop(ctx context.Context)   { s.observation.StartDDGaugeLoop(ctx) }
func (s *Server) StartWarmPoolTelemetryLoop(ctx context.Context) {
	s.observation.StartWarmPoolTelemetryLoop(ctx)
}
func (s *Server) StartThroughputAnomalyDetector(ctx context.Context) {
	s.observation.StartThroughputAnomalyDetector(ctx)
}
