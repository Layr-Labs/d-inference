package routes

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"log/slog"
)

// LogRecordWriteError is shared by queued and direct route persistence.
func LogRecordWriteError(logger *slog.Logger, record *store.InferenceRouteRecord, err error) {
	if err == nil || logger == nil || record == nil {
		return
	}
	logger.Error("inference_routes record write failed",
		"request_id", record.RequestID, "attempt", record.Attempt,
		"provider_id", record.ProviderID, "model", record.Model, "error", err)
}

// LogOutcomeWriteError is shared by queued and direct outcome persistence.
func LogOutcomeWriteError(logger *slog.Logger, requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome, err error) {
	if err == nil || logger == nil || outcome == nil {
		return
	}
	logger.Error("inference_routes outcome update failed",
		"request_id", requestID, "attempt", attempt, "model", model,
		"final_status", outcome.FinalStatus, "error_class", outcome.ErrorClass,
		"error_reason", outcome.ErrorReason, "error", err)
}
