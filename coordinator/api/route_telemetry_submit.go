package api

import (
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/routequeue"
)

// Server entry points for inference_routes telemetry writes. They hand typed
// ops to the batching sink when the Server has one, and otherwise fall back
// to the historical per-write panic-safe goroutine so a Server built directly
// (e.g. &Server{} in tests, which never runs NewServer) keeps working.

// submitRouteRecord persists a routing-decision snapshot off the request
// path. It never blocks: with a sink the record is enqueued (or dropped and
// counted when the buffer is full); without one it is written by its own
// goroutine.
func (s *Server) submitRouteRecord(record *store.InferenceRouteRecord) {
	if s == nil || record == nil {
		return
	}
	if t := s.routeTelemetry; t != nil {
		t.Bind(s.store)
		t.SubmitRoute(record)
		return
	}
	saferun.Go(s.logger, "recordInferenceRoute", func() {
		routequeue.LogRecordWriteError(s.logger, record, s.store.RecordInferenceRoute(record))
	})
}

// submitRouteOutcome persists an outcome merge for (requestID, attempt) off
// the request path with the same never-block contract as submitRouteRecord.
// Callers must have submitted the matching route record first (dispatch
// precedes every commit/terminal), which is what the sink's insert-before-
// update grouping relies on.
func (s *Server) submitRouteOutcome(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil {
		return
	}
	if t := s.routeTelemetry; t != nil {
		t.Bind(s.store)
		t.SubmitOutcome(requestID, attempt, model, outcome)
		return
	}
	saferun.Go(s.logger, "updateInferenceRoute", func() {
		routequeue.LogOutcomeWriteError(s.logger, requestID, attempt, model, outcome,
			s.store.UpdateInferenceRouteOutcome(requestID, attempt, outcome))
	})
}

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
		s.routeTelemetry.Submit(fn)
		return
	}
	saferun.Go(s.logger, name, fn)
}
