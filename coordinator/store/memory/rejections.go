package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// RecordRejection writes a rejected-request record with its counterfactual
// servability snapshot. Best-effort; failures are discarded.
func (s *MemoryStore) RecordRejection(record *store.RejectionRecord) error {
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
func (s *MemoryStore) RejectionRecordsSince(since time.Time) []store.RejectionRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]store.RejectionRecord, 0, len(s.inferenceRejections))
	for i := len(s.inferenceRejections) - 1; i >= 0; i-- {
		r := s.inferenceRejections[i]
		if !since.IsZero() && r.CreatedAt.Before(since) {
			continue
		}
		out = append(out, r)
		if len(out) >= shared.MaxTelemetryReadRows {
			break
		}
	}
	if out == nil {
		return []store.RejectionRecord{}
	}
	return out
}
