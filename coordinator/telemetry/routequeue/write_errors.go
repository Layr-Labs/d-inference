package routequeue

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"log/slog"
)

// LogRecordWriteError is the single diagnostic line for a failed route
// snapshot write; a nil err is a no-op.
func LogRecordWriteError(logger *slog.Logger, record *store.InferenceRouteRecord, err error) {
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

// LogOutcomeWriteError is the single diagnostic line for a failed
// outcome update; a nil err is a no-op.
func LogOutcomeWriteError(logger *slog.Logger, requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome, err error) {
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
