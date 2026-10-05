package memoryhistory

import (
	"bytes"
	"context"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// requestProfileKey is the write-once identity of a profile row, matching the
// Postgres UNIQUE (request_id, attempt).
func requestProfileKey(requestID string, attempt int) string {
	return requestID + "/" + strconv.Itoa(attempt)
}

// rebuildRequestProfileKeysLocked recomputes the write-once key set from the
// retained rows. Caller holds s.mu.
func (s *State) rebuildRequestProfileKeysLocked() {
	s.RequestProfileKeys = make(map[string]struct{}, len(s.RequestProfiles))
	for i := range s.RequestProfiles {
		r := &s.RequestProfiles[i]
		s.RequestProfileKeys[requestProfileKey(r.RequestID, r.Attempt)] = struct{}{}
	}
}

// RecordRequestProfiles appends one row per record, skipping any
// (request_id, attempt) already present (ON CONFLICT DO NOTHING semantics).
// RawMessage fields are cloned so the caller may reuse its buffers.
func (s *State) RecordRequestProfiles(records []*store.RequestProfileRecord) error {
	if len(records) == 0 {
		return nil
	}
	now := time.Now()

	for _, record := range records {
		if record == nil {
			continue
		}
		key := requestProfileKey(record.RequestID, record.Attempt)
		if _, dup := s.RequestProfileKeys[key]; dup {
			continue
		}
		rec := *record
		if rec.CreatedAt.IsZero() {
			rec.CreatedAt = now
		}
		rec.GateRejections = bytes.Clone(shared.JsonbParam(rec.GateRejections))
		rec.Candidates = bytes.Clone(shared.JsonbParam(rec.Candidates))
		rec.ProviderProfile = bytes.Clone(shared.JsonbParam(rec.ProviderProfile))
		s.RequestProfiles = append(s.RequestProfiles, rec)
		s.RequestProfileKeys[key] = struct{}{}
	}
	return nil
}

// RequestProfilesSinceFiltered returns profiles created at or after since,
// newest first (reverse insertion order), capped at maxTelemetryReadRows. It
// applies the filter before the read cap.
func (s *State) RequestProfilesSinceFiltered(since time.Time, filter store.RequestProfileFilter) []store.RequestProfileRecord {

	out := make([]store.RequestProfileRecord, 0, len(s.RequestProfiles))
	for i := len(s.RequestProfiles) - 1; i >= 0; i-- {
		r := s.RequestProfiles[i]
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
func (s *State) RecordFleetSnapshots(rows []store.FleetSnapshotRow) error {
	if len(rows) == 0 {
		return nil
	}
	now := time.Now()

	for i := range rows {
		row := rows[i]
		if row.SampledAt.IsZero() {
			row.SampledAt = now
		}
		row.QueueDepthByModel = bytes.Clone(shared.JsonbParam(row.QueueDepthByModel))
		s.FleetSnapshots = append(s.FleetSnapshots, row)
	}
	return nil
}

// FleetSnapshotsSince returns snapshot rows sampled at or after since, newest
// first (reverse insertion order), capped at maxTelemetryReadRows.
func (s *State) FleetSnapshotsSince(since time.Time) []store.FleetSnapshotRow {

	out := make([]store.FleetSnapshotRow, 0, len(s.FleetSnapshots))
	for i := len(s.FleetSnapshots) - 1; i >= 0; i-- {
		r := s.FleetSnapshots[i]
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
func (s *State) PruneTelemetry(ctx context.Context, profilesBefore, snapshotsBefore time.Time, _ int) (int, error) {

	deleted := 0
	if err := ctx.Err(); err != nil {
		return deleted, err
	}
	if !profilesBefore.IsZero() {
		for id, r := range s.RequestOutcomes {
			if r.ReceivedAt.Before(profilesBefore) {
				delete(s.RequestOutcomes, id)
				deleted++
			}
		}
		kept := s.RequestProfiles[:0:0]
		for i := range s.RequestProfiles {
			if s.RequestProfiles[i].CreatedAt.Before(profilesBefore) {
				deleted++
				continue
			}
			kept = append(kept, s.RequestProfiles[i])
		}
		if len(kept) != len(s.RequestProfiles) {
			s.RequestProfiles = kept
			s.rebuildRequestProfileKeysLocked()
		}
	}
	if err := ctx.Err(); err != nil {
		return deleted, err
	}
	if !snapshotsBefore.IsZero() {
		kept := s.FleetSnapshots[:0:0]
		for i := range s.FleetSnapshots {
			if s.FleetSnapshots[i].SampledAt.Before(snapshotsBefore) {
				deleted++
				continue
			}
			kept = append(kept, s.FleetSnapshots[i])
		}
		s.FleetSnapshots = kept
	}
	return deleted, nil
}
