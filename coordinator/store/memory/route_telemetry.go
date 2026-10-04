package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// RecordInferenceRoute writes or refreshes the routing decision snapshot for a
// request attempt. A refresh keeps the original CreatedAt and, like the
// postgres upsert's COALESCE, keeps an existing error_reason when the fresh
// record carries none.
func (s *MemoryStore) RecordInferenceRoute(record *store.InferenceRouteRecord) error {
	if record == nil {
		return nil
	}
	now := time.Now()

	s.mu.Lock()
	defer s.mu.Unlock()

	s.recordInferenceRouteLocked(record, now)
	return nil
}

// RecordInferenceRoutes applies records in order under one lock; nil records
// are skipped. A later duplicate (request_id, attempt) refreshes the earlier
// one exactly as sequential RecordInferenceRoute calls would.
func (s *MemoryStore) RecordInferenceRoutes(records []*store.InferenceRouteRecord) error {
	if len(records) == 0 {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	for _, record := range records {
		if record != nil {
			s.recordInferenceRouteLocked(record, time.Now())
		}
	}
	return nil
}

func (s *MemoryStore) recordInferenceRouteLocked(record *store.InferenceRouteRecord, now time.Time) {
	rec := *record
	if rec.CreatedAt.IsZero() {
		rec.CreatedAt = now
	}
	if rec.UpdatedAt.IsZero() {
		rec.UpdatedAt = now
	}

	key := shared.InferenceRouteKey(record.RequestID, record.Attempt)
	if idx, ok := s.inferenceRouteIndex[key]; ok {
		existing := s.inferenceRoutes[idx]
		rec.CreatedAt = existing.CreatedAt
		if rec.ErrorReason == "" {
			rec.ErrorReason = existing.ErrorReason
		}
		s.inferenceRoutes[idx] = rec
		return
	}
	s.inferenceRoutes = append(s.inferenceRoutes, rec)
	s.inferenceRouteIndex[key] = len(s.inferenceRoutes) - 1
}

// UpdateInferenceRouteOutcome merges outcome onto the attempt's row (zero
// fields are "not present"). An update for an unknown row is a silent no-op,
// matching the postgres UPDATE that affects zero rows.
func (s *MemoryStore) UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *store.InferenceRouteOutcome) error {
	if outcome == nil {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.updateInferenceRouteOutcomeLocked(requestID, attempt, outcome)
	return nil
}

// UpdateInferenceRouteOutcomes applies updates in order under one lock;
// updates with a nil Outcome are skipped.
func (s *MemoryStore) UpdateInferenceRouteOutcomes(updates []store.InferenceRouteOutcomeUpdate) error {
	if len(updates) == 0 {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	for i := range updates {
		u := &updates[i]
		if u.Outcome != nil {
			s.updateInferenceRouteOutcomeLocked(u.RequestID, u.Attempt, u.Outcome)
		}
	}
	return nil
}

func (s *MemoryStore) updateInferenceRouteOutcomeLocked(requestID string, attempt int, outcome *store.InferenceRouteOutcome) {
	key := shared.InferenceRouteKey(requestID, attempt)
	idx, ok := s.inferenceRouteIndex[key]
	if !ok {
		return
	}

	merged := s.inferenceRouteOutcomes[key]
	mergeInferenceRouteOutcome(&merged, outcome)
	s.inferenceRouteOutcomes[key] = merged
	s.inferenceRoutes[idx].UpdatedAt = time.Now()
}

// InferenceRouteRecordsSince returns route rows created at or after since
// (zero = all), newest first, capped at maxTelemetryReadRows, with each row's
// merged outcome applied.
func (s *MemoryStore) InferenceRouteRecordsSince(since time.Time) []store.InferenceRouteRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]store.InferenceRouteRecord, 0, len(s.inferenceRoutes))
	for i := len(s.inferenceRoutes) - 1; i >= 0; i-- {
		r := s.inferenceRoutes[i]
		if !since.IsZero() && r.CreatedAt.Before(since) {
			continue
		}
		key := shared.InferenceRouteKey(r.RequestID, r.Attempt)
		if outcome, ok := s.inferenceRouteOutcomes[key]; ok {
			shared.ApplyInferenceRouteOutcomeToRecord(&r, outcome)
		}
		out = append(out, r)
		if len(out) >= shared.MaxTelemetryReadRows {
			break
		}
	}
	if out == nil {
		return []store.InferenceRouteRecord{}
	}
	return out
}

// mergeInferenceRouteOutcome applies non-zero outcome fields onto dst. Outcome
// updates are emitted from different goroutines (commit, response relay,
// provider terminal), so treating zero values as "not present" prevents a
// latency-only commit update from erasing a later terminal status or usage row.
func mergeInferenceRouteOutcome(dst *store.InferenceRouteOutcome, src *store.InferenceRouteOutcome) {
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
