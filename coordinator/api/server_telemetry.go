package api

import "github.com/eigeninference/d-inference/coordinator/saferun"

// submitTelemetry enqueues a best-effort telemetry write onto the non-blocking
// routing-telemetry sink. It never blocks the caller (the inference request
// path): when the sink's buffer is full the write is dropped and counted. name
// identifies the write for panic/drop diagnostics.
//
// Nil-safety: a Server constructed directly (e.g. &Server{} in tests, which
// never runs NewServer) has no sink. In that case it falls back to the previous
// behavior — a per-write panic-safe goroutine — so those tests keep working.
func (s *Server) submitTelemetry(name string, fn func()) {
	if s.routeTelemetry != nil {
		s.routeTelemetry.submit(fn)
		return
	}
	saferun.Go(s.logger, name, fn)
}

// Close releases background resources owned by the Server. Currently it stops
// the routing-telemetry sink's worker pool. It is idempotent and never blocks on
// in-flight telemetry writes, so it is safe to defer from main's shutdown path.
func (s *Server) Close() {
	if s.routeTelemetry != nil {
		s.routeTelemetry.close()
	}
}
