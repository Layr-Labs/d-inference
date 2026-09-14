package memory

import (
	"bytes"
	"context"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/recordutil"
	"github.com/eigeninference/d-inference/coordinator/store/internal/routerecord"
)

// requestProfileKey is the write-once identity of a profile row, matching the
// Postgres UNIQUE (request_id, attempt).
func requestProfileKey(requestID string, attempt int) string {
	return requestID + "/" + strconv.Itoa(attempt)
}

// rebuildRequestProfileKeysLocked recomputes the write-once key set from the
// retained rows. Caller holds s.mu.
func (s *Store) rebuildRequestProfileKeysLocked() {
	s.requestProfileKeys = make(map[string]struct{}, len(s.requestProfiles))
	for i := range s.requestProfiles {
		r := &s.requestProfiles[i]
		s.requestProfileKeys[requestProfileKey(r.RequestID, r.Attempt)] = struct{}{}
	}
}

// RecordRequestProfiles appends one row per record, skipping any
// (request_id, attempt) already present (ON CONFLICT DO NOTHING semantics).
// RawMessage fields are cloned so the caller may reuse its buffers.
func (s *Store) RecordRequestProfiles(records []*contracts.RequestProfileRecord) error {
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
		rec.GateRejections = bytes.Clone(recordutil.JsonbParam(rec.GateRejections))
		rec.Candidates = bytes.Clone(recordutil.JsonbParam(rec.Candidates))
		rec.ProviderProfile = bytes.Clone(recordutil.JsonbParam(rec.ProviderProfile))
		s.requestProfiles = append(s.requestProfiles, rec)
		s.requestProfileKeys[key] = struct{}{}
	}
	return nil
}

// RequestProfilesSince returns profiles created at or after since, newest
// first (reverse insertion order), capped at maxTelemetryReadRows.
func (s *Store) RequestProfilesSince(since time.Time) []contracts.RequestProfileRecord {
	return s.RequestProfilesSinceFiltered(since, contracts.RequestProfileFilter{})
}

// RequestProfilesSinceFiltered applies the filter before the read cap.
func (s *Store) RequestProfilesSinceFiltered(since time.Time, filter contracts.RequestProfileFilter) []contracts.RequestProfileRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]contracts.RequestProfileRecord, 0, len(s.requestProfiles))
	for i := len(s.requestProfiles) - 1; i >= 0; i-- {
		r := s.requestProfiles[i]
		if !since.IsZero() && r.CreatedAt.Before(since) {
			continue
		}
		if !filter.Matches(&r) {
			continue
		}
		out = append(out, r)
		if len(out) >= routerecord.MaxTelemetryReadRows {
			break
		}
	}
	return out
}

// RecordFleetSnapshots appends one sampler tick. RawMessage fields are cloned.
func (s *Store) RecordFleetSnapshots(rows []contracts.FleetSnapshotRow) error {
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
		row.QueueDepthByModel = bytes.Clone(recordutil.JsonbParam(row.QueueDepthByModel))
		s.fleetSnapshots = append(s.fleetSnapshots, row)
	}
	return nil
}

// FleetSnapshotsSince returns snapshot rows sampled at or after since, newest
// first (reverse insertion order), capped at maxTelemetryReadRows.
func (s *Store) FleetSnapshotsSince(since time.Time) []contracts.FleetSnapshotRow {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]contracts.FleetSnapshotRow, 0, len(s.fleetSnapshots))
	for i := len(s.fleetSnapshots) - 1; i >= 0; i-- {
		r := s.fleetSnapshots[i]
		if !since.IsZero() && r.SampledAt.Before(since) {
			continue
		}
		out = append(out, r)
		if len(out) >= routerecord.MaxTelemetryReadRows {
			break
		}
	}
	return out
}

// PruneTelemetry drops profiles created before profilesBefore and snapshots
// sampled before snapshotsBefore. There is no per-batch transaction in the
// memory store, so batch is accepted for interface parity and ignored; ctx is
// checked before each table. A zero cutoff prunes nothing for that table.
func (s *Store) PruneTelemetry(ctx context.Context, profilesBefore, snapshotsBefore time.Time, _ int) (int, error) {
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
