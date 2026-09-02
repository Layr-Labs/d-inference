package store

// Routing-telemetry paths for MemoryStore. The batch methods are the
// single-row methods applied in order under ONE lock acquisition, so both
// backends expose identical per-row semantics.

import "time"

// RecordInferenceRoute writes or refreshes the routing decision snapshot for a
// request attempt. A refresh keeps the original CreatedAt.
func (s *MemoryStore) RecordInferenceRoute(record *InferenceRouteRecord) error {
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
func (s *MemoryStore) RecordInferenceRoutes(records []*InferenceRouteRecord) error {
	if len(records) == 0 {
		return nil
	}
	now := time.Now()

	s.mu.Lock()
	defer s.mu.Unlock()

	for _, record := range records {
		if record != nil {
			s.recordInferenceRouteLocked(record, now)
		}
	}
	return nil
}

func (s *MemoryStore) recordInferenceRouteLocked(record *InferenceRouteRecord, now time.Time) {
	rec := *record
	if rec.CreatedAt.IsZero() {
		rec.CreatedAt = now
	}
	if rec.UpdatedAt.IsZero() {
		rec.UpdatedAt = now
	}

	key := inferenceRouteKey(record.RequestID, record.Attempt)
	if idx, ok := s.inferenceRouteIndex[key]; ok {
		rec.CreatedAt = s.inferenceRoutes[idx].CreatedAt
		if rec.UpdatedAt.IsZero() {
			rec.UpdatedAt = now
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
func (s *MemoryStore) UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *InferenceRouteOutcome) error {
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
func (s *MemoryStore) UpdateInferenceRouteOutcomes(updates []InferenceRouteOutcomeUpdate) error {
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

func (s *MemoryStore) updateInferenceRouteOutcomeLocked(requestID string, attempt int, outcome *InferenceRouteOutcome) {
	key := inferenceRouteKey(requestID, attempt)
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
func (s *MemoryStore) InferenceRouteRecordsSince(since time.Time) []InferenceRouteRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]InferenceRouteRecord, 0, len(s.inferenceRoutes))
	for i := len(s.inferenceRoutes) - 1; i >= 0; i-- {
		r := s.inferenceRoutes[i]
		if !since.IsZero() && r.CreatedAt.Before(since) {
			continue
		}
		key := inferenceRouteKey(r.RequestID, r.Attempt)
		if outcome, ok := s.inferenceRouteOutcomes[key]; ok {
			applyInferenceRouteOutcomeToRecord(&r, outcome)
		}
		out = append(out, r)
		if len(out) >= maxTelemetryReadRows {
			break
		}
	}
	if out == nil {
		return []InferenceRouteRecord{}
	}
	return out
}
