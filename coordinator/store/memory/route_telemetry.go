package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/routerecord"
)

// RecordInferenceRoute writes or refreshes the routing decision snapshot for a
// request attempt. A refresh keeps the original CreatedAt and, like the
// postgres upsert's COALESCE, keeps an existing error_reason when the fresh
// record carries none.
func (s *Store) RecordInferenceRoute(record *contracts.InferenceRouteRecord) error {
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
func (s *Store) RecordInferenceRoutes(records []*contracts.InferenceRouteRecord) error {
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

func (s *Store) recordInferenceRouteLocked(record *contracts.InferenceRouteRecord, now time.Time) {
	rec := *record
	if rec.CreatedAt.IsZero() {
		rec.CreatedAt = now
	}
	if rec.UpdatedAt.IsZero() {
		rec.UpdatedAt = now
	}

	key := routerecord.InferenceRouteKey(record.RequestID, record.Attempt)
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
func (s *Store) UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *contracts.InferenceRouteOutcome) error {
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
func (s *Store) UpdateInferenceRouteOutcomes(updates []contracts.InferenceRouteOutcomeUpdate) error {
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

func (s *Store) updateInferenceRouteOutcomeLocked(requestID string, attempt int, outcome *contracts.InferenceRouteOutcome) {
	key := routerecord.InferenceRouteKey(requestID, attempt)
	idx, ok := s.inferenceRouteIndex[key]
	if !ok {
		return
	}

	merged := s.inferenceRouteOutcomes[key]
	routerecord.MergeInferenceRouteOutcome(&merged, outcome)
	s.inferenceRouteOutcomes[key] = merged
	s.inferenceRoutes[idx].UpdatedAt = time.Now()
}

// InferenceRouteRecordsSince returns route rows created at or after since
// (zero = all), newest first, capped at maxTelemetryReadRows, with each row's
// merged outcome applied.
func (s *Store) InferenceRouteRecordsSince(since time.Time) []contracts.InferenceRouteRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]contracts.InferenceRouteRecord, 0, min(len(s.inferenceRoutes), routerecord.MaxTelemetryReadRows))
	for i := len(s.inferenceRoutes) - 1; i >= 0; i-- {
		r := s.inferenceRoutes[i]
		if !since.IsZero() && r.CreatedAt.Before(since) {
			continue
		}
		key := routerecord.InferenceRouteKey(r.RequestID, r.Attempt)
		if outcome, ok := s.inferenceRouteOutcomes[key]; ok {
			routerecord.ApplyInferenceRouteOutcomeToRecord(&r, outcome)
		}
		out = append(out, r)
		if len(out) >= routerecord.MaxTelemetryReadRows {
			break
		}
	}
	if out == nil {
		return []contracts.InferenceRouteRecord{}
	}
	return out
}
