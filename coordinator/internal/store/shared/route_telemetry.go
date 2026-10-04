package shared

import (
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// inferenceRouteKey is the (request_id, attempt) identity of a route row, the
// same key the memory index and the postgres UNIQUE(request_id, attempt)
// constraint use.
func InferenceRouteKey(requestID string, attempt int) string {
	return requestID + "/" + strconv.Itoa(attempt)
}

func ApplyInferenceRouteOutcomeToRecord(rec *store.InferenceRouteRecord, outcome store.InferenceRouteOutcome) {
	if rec == nil {
		return
	}
	rec.FinalStatus = outcome.FinalStatus
	rec.ErrorCode = outcome.ErrorCode
	rec.ErrorClass = outcome.ErrorClass
	// Outcome updates only ever set error_reason when they carry one (the
	// postgres UPDATE is COALESCE(NULLIF($6, ''), error_reason)); a reason the
	// route record itself was written with must survive reason-less updates.
	if outcome.ErrorReason != "" {
		rec.ErrorReason = outcome.ErrorReason
	}
	rec.PromptTokens = outcome.PromptTokens
	rec.CompletionTokens = outcome.CompletionTokens
	rec.ReasoningTokens = outcome.ReasoningTokens
	rec.CostMicroUSD = outcome.CostMicroUSD
	rec.ActualTTFTMs = outcome.ActualTTFTMs
	rec.DispatchToFirstChunkMs = outcome.DispatchToFirstChunkMs
	rec.TotalDurationMs = outcome.TotalDurationMs
	rec.ParseMs = outcome.ParseMs
	rec.ReserveMs = outcome.ReserveMs
	rec.RouteMs = outcome.RouteMs
	rec.EncryptMs = outcome.EncryptMs
	rec.QueueWaitMs = outcome.QueueWaitMs
	rec.DispatchMs = outcome.DispatchMs
	rec.ActualDecodeTPS = outcome.ActualDecodeTPS
	rec.AdmittedButFailed = outcome.AdmittedButFailed
	rec.UsedBackup = outcome.UsedBackup
	rec.BackupWon = outcome.BackupWon
}
