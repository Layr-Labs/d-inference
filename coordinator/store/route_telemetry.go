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
	if src.ErrorReason != "" {
		dst.ErrorReason = src.ErrorReason
	}
	if src.PromptTokens != 0 {
		dst.PromptTokens = src.PromptTokens
	}
	// CompletionTokensSet force-writes the count even when 0 (terminal cancel/
	// error/timeout rows deliver 0 tokens and must persist 0, not be skipped as a
	// zero-value). The flag is sticky so a later commit/latency update with the
	// default (unset) flag cannot un-set an explicitly recorded 0.
	if src.CompletionTokensSet {
		dst.CompletionTokens = src.CompletionTokens
		dst.CompletionTokensSet = true
	} else if src.CompletionTokens != 0 {
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
	if src.MediaFetchMs != 0 {
		dst.MediaFetchMs = src.MediaFetchMs
	}
	if src.CacheOutcome != "" {
		dst.CacheOutcome = src.CacheOutcome
		dst.CacheTier = src.CacheTier
		dst.CachedTokens = src.CachedTokens
		dst.PrefillTokensSaved = src.PrefillTokensSaved
		dst.CacheStageMs = src.CacheStageMs
	}
	if src.ClientOutcome != "" {
		dst.ClientOutcome = src.ClientOutcome
	}
	if src.ProviderOutcome != "" {
		dst.ProviderOutcome = src.ProviderOutcome
	}
	if src.BillingOutcome != "" {
		dst.BillingOutcome = src.BillingOutcome
	}
	if src.ResponseCommitted {
		dst.ResponseCommitted = true
	}
	if src.IsFinalAttempt {
		dst.IsFinalAttempt = true
	}
	if src.TotalAttempts != 0 {
		dst.TotalAttempts = src.TotalAttempts
	}
	if src.TerminalSource != "" {
		dst.TerminalSource = src.TerminalSource
	}
	if src.ReservedMicroUSD != 0 {
		dst.ReservedMicroUSD = src.ReservedMicroUSD
	}
	if src.SettledMicroUSD != 0 {
		dst.SettledMicroUSD = src.SettledMicroUSD
	}
	if src.OverageMicroUSD != 0 {
		dst.OverageMicroUSD = src.OverageMicroUSD
	}
	if src.RefundMicroUSD != 0 {
		dst.RefundMicroUSD = src.RefundMicroUSD
	}
}

func applyInferenceRouteOutcomeToRecord(rec *InferenceRouteRecord, outcome InferenceRouteOutcome) {
	if rec == nil {
		return
	}
	rec.FinalStatus = outcome.FinalStatus
	rec.ErrorCode = outcome.ErrorCode
	rec.ErrorClass = outcome.ErrorClass
	rec.ErrorReason = outcome.ErrorReason
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
	rec.MediaFetchMs = outcome.MediaFetchMs
	rec.CacheOutcome = outcome.CacheOutcome
	rec.CacheTier = outcome.CacheTier
	rec.CachedTokens = outcome.CachedTokens
	rec.PrefillTokensSaved = outcome.PrefillTokensSaved
	rec.CacheStageMs = outcome.CacheStageMs
	rec.ClientOutcome = outcome.ClientOutcome
	rec.ProviderOutcome = outcome.ProviderOutcome
	rec.BillingOutcome = outcome.BillingOutcome
	rec.ResponseCommitted = outcome.ResponseCommitted
	rec.IsFinalAttempt = outcome.IsFinalAttempt
	rec.TotalAttempts = outcome.TotalAttempts
	rec.TerminalSource = outcome.TerminalSource
	rec.ReservedMicroUSD = outcome.ReservedMicroUSD
	rec.SettledMicroUSD = outcome.SettledMicroUSD
	rec.OverageMicroUSD = outcome.OverageMicroUSD
	rec.RefundMicroUSD = outcome.RefundMicroUSD
}
