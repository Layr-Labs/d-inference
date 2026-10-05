package observation

// Server entry points for inference_routes telemetry writes. They hand typed
// ops to the batching sink when configured, and otherwise retain the direct
// per-write panic-safe goroutine path.

import (
	"github.com/eigeninference/d-inference/coordinator/internal/observation/routes"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// SubmitRouteRecord persists a routing-decision snapshot off the request
// path. It never blocks: with a sink the record is enqueued (or dropped and
// counted when the buffer is full); without one it is written by its own
// goroutine.
func (s *Owner) SubmitRouteRecord(record *store.InferenceRouteRecord) {
	if s == nil || record == nil {
		return
	}
	if t := s.routeTelemetry; t != nil {
		t.Bind(s.store)
		t.SubmitRoute(record)
		return
	}
	saferun.Go(s.logger, "recordInferenceRoute", func() {
		routes.LogRecordWriteError(s.logger, record, s.store.RecordInferenceRoute(record))
	})
}

// SubmitRouteOutcome persists an outcome merge for (requestID, attempt) off
// the request path with the same never-block contract as SubmitRouteRecord.
// Callers must have submitted the matching route record first (dispatch
// precedes every commit/terminal), which is what the sink's insert-before-
// update grouping relies on.
func (s *Owner) SubmitRouteOutcome(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil {
		return
	}
	if t := s.routeTelemetry; t != nil {
		t.Bind(s.store)
		t.SubmitOutcome(requestID, attempt, model, outcome)
		return
	}
	saferun.Go(s.logger, "updateInferenceRoute", func() {
		routes.LogOutcomeWriteError(s.logger, requestID, attempt, model, outcome,
			s.store.UpdateInferenceRouteOutcome(requestID, attempt, outcome))
	})
}
