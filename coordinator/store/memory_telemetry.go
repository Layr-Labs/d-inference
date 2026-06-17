package store

import (
	"strconv"
	"time"
)

// RecordInferenceRoute writes the routing decision snapshot for a request
// attempt. Best-effort; failures are discarded.
func (s *MemoryStore) RecordInferenceRoute(record *InferenceRouteRecord) error {
	if record == nil {
		return nil
	}

	now := time.Now()
	rec := *record
	if rec.CreatedAt.IsZero() {
		rec.CreatedAt = now
	}
	if rec.UpdatedAt.IsZero() {
		rec.UpdatedAt = now
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.inferenceRoutes = append(s.inferenceRoutes, rec)
	key := record.RequestID + "/" + strconv.Itoa(record.Attempt)
	s.inferenceRouteIndex[key] = len(s.inferenceRoutes) - 1
	return nil
}

// UpdateInferenceRouteOutcome updates the attempt with final outcome data.
// Best-effort; failures are discarded.
func (s *MemoryStore) UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *InferenceRouteOutcome) error {
	if outcome == nil {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	key := requestID + "/" + strconv.Itoa(attempt)
	idx, ok := s.inferenceRouteIndex[key]
	if !ok {
		return nil
	}

	s.inferenceRouteOutcomes[key] = *outcome
	s.inferenceRoutes[idx].UpdatedAt = time.Now()
	return nil
}

// InferenceRouteRecordsSince returns routing records created at or after the
// given time. Zero since returns all records.
func (s *MemoryStore) InferenceRouteRecordsSince(since time.Time) []InferenceRouteRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]InferenceRouteRecord, 0, len(s.inferenceRoutes))
	for i := len(s.inferenceRoutes) - 1; i >= 0; i-- {
		r := s.inferenceRoutes[i]
		if !since.IsZero() && r.CreatedAt.Before(since) {
			continue
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

// RecordRejection writes a rejected-request record with its counterfactual
// servability snapshot. Best-effort; failures are discarded.
func (s *MemoryStore) RecordRejection(record *RejectionRecord) error {
	if record == nil {
		return nil
	}

	rec := *record
	if rec.CreatedAt.IsZero() {
		rec.CreatedAt = time.Now()
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.inferenceRejections = append(s.inferenceRejections, rec)
	return nil
}

// RejectionRecordsSince returns rejection records created at or after the
// given time. Zero since returns all records.
func (s *MemoryStore) RejectionRecordsSince(since time.Time) []RejectionRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]RejectionRecord, 0, len(s.inferenceRejections))
	for i := len(s.inferenceRejections) - 1; i >= 0; i-- {
		r := s.inferenceRejections[i]
		if !since.IsZero() && r.CreatedAt.Before(since) {
			continue
		}
		out = append(out, r)
		if len(out) >= maxTelemetryReadRows {
			break
		}
	}
	if out == nil {
		return []RejectionRecord{}
	}
	return out
}
