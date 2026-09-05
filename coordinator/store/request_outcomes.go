package store

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/outcomes"
)

// RequestOutcomeStore is unsampled request accounting. Reads are bounded and
// use receipt-time half-open windows, regardless of terminal/persistence time.
type RequestOutcomeStore interface {
	RecordRequestOutcomes([]*outcomes.Record) error
	RequestOutcomesBetween(context.Context, time.Time, time.Time, int) ([]outcomes.Record, error)
	PruneRequestOutcomes(context.Context, time.Time, int) (int, error)
}

func encodeRequestOutcome(r *outcomes.Record) ([]byte, error) {
	if strings.TrimSpace(r.CoordRequestID) == "" || len(r.CoordRequestID) > 64 || r.Revision < 1 || r.SchemaVersion != outcomes.SchemaVersion || r.ReceivedAt.IsZero() || r.ObservedAt.IsZero() || len(r.Attempts) > outcomes.MaxAttempts {
		return nil, errors.New("invalid request outcome identity, version or bounds")
	}
	return json.Marshal(r)
}

func outcomeReadLimit(limit int) int {
	if limit <= 0 || limit > maxTelemetryReadRows {
		return maxTelemetryReadRows
	}
	return limit
}

// Memory storage retains encoded immutable snapshots, so callers cannot mutate
// stored pointer fields or attempt slices after persistence or reads.
func (s *MemoryStore) RecordRequestOutcomes(records []*outcomes.Record) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.requestOutcomes == nil {
		s.requestOutcomes = make(map[string]json.RawMessage)
	}
	for _, r := range records {
		if r == nil {
			continue
		}
		encoded, err := encodeRequestOutcome(r)
		if err != nil {
			return err
		}
		if previous := s.requestOutcomes[r.CoordRequestID]; previous != nil {
			var old outcomes.Record
			if err := json.Unmarshal(previous, &old); err != nil {
				return err
			}
			identityConflict := !old.ReceivedAt.Equal(r.ReceivedAt) || old.Endpoint != r.Endpoint
			if r.Revision <= old.Revision || identityConflict {
				if r.EvidenceConflict || identityConflict || r.Revision == old.Revision && string(previous) != string(encoded) {
					old.EvidenceConflict = true
					s.requestOutcomes[r.CoordRequestID], _ = json.Marshal(old)
				}
				continue
			}
			copy := *r
			copy.EvidenceConflict = copy.EvidenceConflict || old.EvidenceConflict
			encoded, _ = json.Marshal(&copy)
		}
		s.requestOutcomes[r.CoordRequestID] = encoded
	}
	return nil
}

func (s *MemoryStore) RequestOutcomesBetween(ctx context.Context, from, to time.Time, limit int) ([]outcomes.Record, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rows := []outcomes.Record{}
	for _, raw := range s.requestOutcomes {
		var r outcomes.Record
		if err := json.Unmarshal(raw, &r); err != nil {
			return nil, err
		}
		if !r.ReceivedAt.Before(from) && r.ReceivedAt.Before(to) {
			rows = append(rows, r)
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].ReceivedAt.Equal(rows[j].ReceivedAt) {
			return rows[i].CoordRequestID < rows[j].CoordRequestID
		}
		return rows[i].ReceivedAt.After(rows[j].ReceivedAt)
	})
	if len(rows) > outcomeReadLimit(limit) {
		rows = rows[:outcomeReadLimit(limit)]
	}
	return rows, nil
}

func (s *MemoryStore) PruneRequestOutcomes(ctx context.Context, before time.Time, batch int) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if batch <= 0 || batch > 5000 {
		batch = 5000
	}
	deleted := 0
	for id, raw := range s.requestOutcomes {
		var r outcomes.Record
		if err := json.Unmarshal(raw, &r); err != nil {
			return deleted, err
		}
		if r.ReceivedAt.Before(before) {
			delete(s.requestOutcomes, id)
			deleted++
		}
		if deleted == batch {
			break
		}
	}
	return deleted, nil
}
