package memory

import (
	"bytes"
	"context"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

// requestProfileKey is the write-once identity of a profile row, matching the
// Postgres UNIQUE (request_id, attempt).
func requestProfileKey(requestID string, attempt int) string {
	return requestID + "/" + strconv.Itoa(attempt)
}

// rebuildRequestProfileKeysLocked recomputes the write-once key set from the
// retained rows. Caller holds s.mu.
func (s *MemoryStore) rebuildRequestProfileKeysLocked() {
	s.requestProfileKeys = make(map[string]struct{}, len(s.requestProfiles))
	for i := range s.requestProfiles {
		r := &s.requestProfiles[i]
		s.requestProfileKeys[requestProfileKey(r.RequestID, r.Attempt)] = struct{}{}
	}
}

// RecordRequestProfiles appends one row per record, skipping any
// (request_id, attempt) already present (ON CONFLICT DO NOTHING semantics).
// RawMessage fields are cloned so the caller may reuse its buffers.
func (s *MemoryStore) RecordRequestProfiles(records []*store.RequestProfileRecord) error {
	if len(records) == 0 {
		return nil
	}
	now := time.Now()

	s.mu.Lock()
	defer s.mu.Unlock()

	for _, record := range records {
		if record == nil {
			continue
		}
		key := requestProfileKey(record.RequestID, record.Attempt)
		if _, dup := s.requestProfileKeys[key]; dup {
			continue
		}
		rec := *record
		if rec.CreatedAt.IsZero() {
			rec.CreatedAt = now
		}
		rec.GateRejections = bytes.Clone(shared.JsonbParam(rec.GateRejections))
		rec.Candidates = bytes.Clone(shared.JsonbParam(rec.Candidates))
		rec.ProviderProfile = bytes.Clone(shared.JsonbParam(rec.ProviderProfile))
		s.requestProfiles = append(s.requestProfiles, rec)
		s.requestProfileKeys[key] = struct{}{}
	}
	return nil
}

// RequestProfilesSinceFiltered returns profiles created at or after since,
// newest first (reverse insertion order), capped at maxTelemetryReadRows. It
// applies the filter before the read cap.
func (s *MemoryStore) RequestProfilesSinceFiltered(since time.Time, filter store.RequestProfileFilter) []store.RequestProfileRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]store.RequestProfileRecord, 0, len(s.requestProfiles))
	for i := len(s.requestProfiles) - 1; i >= 0; i-- {
		r := s.requestProfiles[i]
		if !since.IsZero() && r.CreatedAt.Before(since) {
			continue
		}
		if !filter.Matches(&r) {
			continue
		}
		out = append(out, r)
		if len(out) >= shared.MaxTelemetryReadRows {
			break
		}
	}
	return out
}

// RecordFleetSnapshots appends one sampler tick. RawMessage fields are cloned.
func (s *MemoryStore) RecordFleetSnapshots(rows []store.FleetSnapshotRow) error {
	if len(rows) == 0 {
		return nil
	}
	now := time.Now()

	s.mu.Lock()
	defer s.mu.Unlock()

	for i := range rows {
		row := rows[i]
		if row.SampledAt.IsZero() {
			row.SampledAt = now
		}
		row.QueueDepthByModel = bytes.Clone(shared.JsonbParam(row.QueueDepthByModel))
		s.fleetSnapshots = append(s.fleetSnapshots, row)
	}
	return nil
}

// FleetSnapshotsSince returns snapshot rows sampled at or after since, newest
// first (reverse insertion order), capped at maxTelemetryReadRows.
func (s *MemoryStore) FleetSnapshotsSince(since time.Time) []store.FleetSnapshotRow {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]store.FleetSnapshotRow, 0, len(s.fleetSnapshots))
	for i := len(s.fleetSnapshots) - 1; i >= 0; i-- {
		r := s.fleetSnapshots[i]
		if !since.IsZero() && r.SampledAt.Before(since) {
			continue
		}
		out = append(out, r)
		if len(out) >= shared.MaxTelemetryReadRows {
			break
		}
	}
	return out
}

// PruneTelemetry drops profiles created before profilesBefore and snapshots
// sampled before snapshotsBefore. There is no per-batch transaction in the
// memory store, so batch is accepted for interface parity and ignored; ctx is
// checked before each table. A zero cutoff prunes nothing for that table.
func (s *MemoryStore) PruneTelemetry(ctx context.Context, profilesBefore, snapshotsBefore time.Time, _ int) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	deleted := 0
	if err := ctx.Err(); err != nil {
		return deleted, err
	}
	if !profilesBefore.IsZero() {
		for id, r := range s.requestOutcomes {
			if r.ReceivedAt.Before(profilesBefore) {
				delete(s.requestOutcomes, id)
				deleted++
			}
		}
		kept := s.requestProfiles[:0:0]
		for i := range s.requestProfiles {
			if s.requestProfiles[i].CreatedAt.Before(profilesBefore) {
				deleted++
				continue
			}
			kept = append(kept, s.requestProfiles[i])
		}
		if len(kept) != len(s.requestProfiles) {
			s.requestProfiles = kept
			s.rebuildRequestProfileKeysLocked()
		}
	}
	if err := ctx.Err(); err != nil {
		return deleted, err
	}
	if !snapshotsBefore.IsZero() {
		kept := s.fleetSnapshots[:0:0]
		for i := range s.fleetSnapshots {
			if s.fleetSnapshots[i].SampledAt.Before(snapshotsBefore) {
				deleted++
				continue
			}
			kept = append(kept, s.fleetSnapshots[i])
		}
		s.fleetSnapshots = kept
	}
	return deleted, nil
}
