package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/routerecord"
)

// RecordRejection writes a rejected-request record with its counterfactual
// servability snapshot. Best-effort; failures are discarded.
func (s *Store) RecordRejection(record *contracts.RejectionRecord) error {
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
func (s *Store) RejectionRecordsSince(since time.Time) []contracts.RejectionRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]contracts.RejectionRecord, 0, len(s.inferenceRejections))
	for i := len(s.inferenceRejections) - 1; i >= 0; i-- {
		r := s.inferenceRejections[i]
		if !since.IsZero() && r.CreatedAt.Before(since) {
			continue
		}
		out = append(out, r)
		if len(out) >= routerecord.MaxTelemetryReadRows {
			break
		}
	}
	if out == nil {
		return []contracts.RejectionRecord{}
	}
	return out
}
