package store

import "strconv"

// inferenceRouteKey is the (request_id, attempt) identity of a route row, the
// same key the memory index and the postgres UNIQUE(request_id, attempt)
// constraint use.
func inferenceRouteKey(requestID string, attempt int) string {
	return requestID + "/" + strconv.Itoa(attempt)
}

// splitInferenceRouteBatches partitions records, preserving order, into
// slices that are safe to write as ONE multi-row upsert each:
//
//   - a slice never contains the same (request_id, attempt) twice, because a
//     single INSERT ... ON CONFLICT DO UPDATE cannot affect one row a second
//     time — the duplicate starts the next slice, so the later record refreshes
//     the earlier one exactly as sequential single-row calls would;
//   - a slice holds at most maxRows records (bind-parameter budget).
//
// Nil records are dropped. maxRows <= 0 means unbounded.
func splitInferenceRouteBatches(records []*InferenceRouteRecord, maxRows int) [][]*InferenceRouteRecord {
	var out [][]*InferenceRouteRecord
	var cur []*InferenceRouteRecord
	seen := map[string]struct{}{}
	flush := func() {
		if len(cur) > 0 {
			out = append(out, cur)
			cur = nil
			seen = map[string]struct{}{}
		}
	}
	for _, r := range records {
		if r == nil {
			continue
		}
		key := inferenceRouteKey(r.RequestID, r.Attempt)
		if _, dup := seen[key]; dup || (maxRows > 0 && len(cur) >= maxRows) {
			flush()
		}
		seen[key] = struct{}{}
		cur = append(cur, r)
	}
	flush()
	return out
}

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
}

func applyInferenceRouteOutcomeToRecord(rec *InferenceRouteRecord, outcome InferenceRouteOutcome) {
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
