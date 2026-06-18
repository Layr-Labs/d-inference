package store

// mergeInferenceRouteOutcome applies non-zero outcome fields onto dst. Outcome
// updates are emitted from different goroutines (commit, response relay,
// provider terminal), so treating zero values as "not present" prevents a
// latency-only commit update from erasing a later terminal status or usage row.
func mergeInferenceRouteOutcome(dst *InferenceRouteOutcome, src *InferenceRouteOutcome) {
	if dst == nil || src == nil {
		return
	}
	if src.FinalStatus != "" {
		dst.FinalStatus = src.FinalStatus
	}
	if src.ErrorCode != 0 {
		dst.ErrorCode = src.ErrorCode
	}
	if src.ErrorClass != "" {
		dst.ErrorClass = src.ErrorClass
	}
	if src.PromptTokens != 0 {
		dst.PromptTokens = src.PromptTokens
	}
	if src.CompletionTokens != 0 {
		dst.CompletionTokens = src.CompletionTokens
	}
	if src.ReasoningTokens != 0 {
		dst.ReasoningTokens = src.ReasoningTokens
	}
	if src.CostMicroUSD != 0 {
		dst.CostMicroUSD = src.CostMicroUSD
	}
	if src.ActualTTFTMs != 0 {
		dst.ActualTTFTMs = src.ActualTTFTMs
	}
	if src.DispatchToFirstChunkMs != 0 {
		dst.DispatchToFirstChunkMs = src.DispatchToFirstChunkMs
	}
	if src.TotalDurationMs != 0 {
		dst.TotalDurationMs = src.TotalDurationMs
	}
	if src.ParseMs != 0 {
		dst.ParseMs = src.ParseMs
	}
	if src.ReserveMs != 0 {
		dst.ReserveMs = src.ReserveMs
	}
	if src.RouteMs != 0 {
		dst.RouteMs = src.RouteMs
	}
	if src.EncryptMs != 0 {
		dst.EncryptMs = src.EncryptMs
	}
	if src.QueueWaitMs != 0 {
		dst.QueueWaitMs = src.QueueWaitMs
	}
	if src.DispatchMs != 0 {
		dst.DispatchMs = src.DispatchMs
	}
	if src.ActualDecodeTPS != 0 {
		dst.ActualDecodeTPS = src.ActualDecodeTPS
	}
	if src.AdmittedButFailed {
		dst.AdmittedButFailed = true
	}
	if src.UsedBackup {
		dst.UsedBackup = true
	}
	if src.BackupWon {
		dst.BackupWon = true
	}
}

func applyInferenceRouteOutcomeToRecord(rec *InferenceRouteRecord, outcome InferenceRouteOutcome) {
	if rec == nil {
		return
	}
	rec.FinalStatus = outcome.FinalStatus
	rec.ErrorCode = outcome.ErrorCode
	rec.ErrorClass = outcome.ErrorClass
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
