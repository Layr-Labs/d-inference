package store

import (
	"bytes"
	"context"
	"encoding/json"
	"sort"
	"time"
)

func cloneRequestOutcome(r RequestOutcomeRecord) RequestOutcomeRecord {
	// All fields are bounded scalars and a bounded attempt slice. Clone pointers too.
	b, _ := json.Marshal(r)
	var out RequestOutcomeRecord
	_ = json.Unmarshal(b, &out)
	return out
}

func (s *MemoryStore) RecordRequestOutcomes(ctx context.Context, records []RequestOutcomeRecord) error {
	for _, r := range records {
		if err := validateRequestOutcome(r); err != nil {
			return err
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.requestOutcomes == nil {
		s.requestOutcomes = make(map[string]RequestOutcomeRecord)
	}
	for _, r := range records {
		old, exists := s.requestOutcomes[r.CoordRequestID]
		left, right := old, r
		left.EvidenceConflict = false
		right.EvidenceConflict = false
		oldJSON, _ := json.Marshal(left)
		newJSON, _ := json.Marshal(right)
		conflict := exists && (!old.ReceivedAt.Equal(r.ReceivedAt) || old.Endpoint != r.Endpoint || (old.Revision == r.Revision && !bytes.Equal(oldJSON, newJSON)))
		if exists && r.Revision <= old.Revision {
			old.EvidenceConflict = old.EvidenceConflict || conflict || r.EvidenceConflict
			s.requestOutcomes[r.CoordRequestID] = old
			continue
		}
		if exists {
			r.ReceivedAt = old.ReceivedAt
			r.Endpoint = old.Endpoint
		}
		r.EvidenceConflict = r.EvidenceConflict || old.EvidenceConflict || conflict
		s.requestOutcomes[r.CoordRequestID] = cloneRequestOutcome(r)
	}
	return nil
}

func (s *MemoryStore) RequestOutcomes(ctx context.Context, since, until time.Time, limit int) ([]RequestOutcomeRecord, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if limit <= 0 || limit > maxTelemetryReadRows {
		limit = maxTelemetryReadRows
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]RequestOutcomeRecord, 0)
	for _, r := range s.requestOutcomes {
		if !r.ReceivedAt.Before(since) && r.ReceivedAt.Before(until) {
			out = append(out, cloneRequestOutcome(r))
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].ReceivedAt.Equal(out[j].ReceivedAt) {
			return out[i].CoordRequestID < out[j].CoordRequestID
		}
		return out[i].ReceivedAt.Before(out[j].ReceivedAt)
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
