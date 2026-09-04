package api

// Server entry points for inference_routes telemetry writes. They hand typed
// ops to the batching sink when the Server has one, and otherwise fall back
// to the historical per-write panic-safe goroutine so a Server built directly
// (e.g. &Server{} in tests, which never runs NewServer) keeps working.

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// submitRouteRecord persists a routing-decision snapshot off the request
// path. It never blocks: with a sink the record is enqueued (or dropped and
// counted when the buffer is full); without one it is written by its own
// goroutine.
func (s *Server) submitRouteRecord(record *store.InferenceRouteRecord) {
	if s == nil || record == nil {
		return
	}
	if t := s.routeTelemetry; t != nil {
		t.bind(s.store)
		t.submitRoute(record)
		return
	}
	saferun.Go(s.logger, "recordInferenceRoute", func() {
		logRouteRecordWriteError(s.logger, record, s.store.RecordInferenceRoute(record))
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
		t.bind(s.store)
		t.submitOutcome(requestID, attempt, model, outcome)
		return
	}
	saferun.Go(s.logger, "updateInferenceRoute", func() {
		logRouteOutcomeWriteError(s.logger, requestID, attempt, model, outcome,
			s.store.UpdateInferenceRouteOutcome(requestID, attempt, outcome))
	})
}

// submitRejectionRecord persists a FINAL rejection-ledger row (servability
// already decided) off the request path with the same never-block contract
// as submitRouteRecord: with a sink the row joins its group's one multi-row
// insert; without one it is written by its own goroutine.
func (s *Server) submitRejectionRecord(record *store.RejectionRecord) {
	if s == nil || record == nil || s.store == nil {
		return
	}
	if t := s.routeTelemetry; t != nil {
		t.bind(s.store)
		t.submitRejection(record)
		return
	}
	saferun.Go(s.logger, "recordRejection", func() {
		_ = s.store.RecordRejection(record)
	})
}

// logRouteRecordWriteError is the single diagnostic line for a failed route
// snapshot write; a nil err is a no-op.
func logRouteRecordWriteError(logger *slog.Logger, record *store.InferenceRouteRecord, err error) {
	if err == nil || logger == nil || record == nil {
		return
	}
	logger.Error("inference_routes record write failed",
		"request_id", record.RequestID,
		"attempt", record.Attempt,
		"provider_id", record.ProviderID,
		"model", record.Model,
		"error", err,
	)
}

// logRouteOutcomeWriteError is the single diagnostic line for a failed
// outcome update; a nil err is a no-op.
func logRouteOutcomeWriteError(logger *slog.Logger, requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome, err error) {
	if err == nil || logger == nil || outcome == nil {
		return
	}
	logger.Error("inference_routes outcome update failed",
		"request_id", requestID,
		"attempt", attempt,
		"model", model,
		"final_status", outcome.FinalStatus,
		"error_class", outcome.ErrorClass,
		"error_reason", outcome.ErrorReason,
		"error", err,
	)
}
