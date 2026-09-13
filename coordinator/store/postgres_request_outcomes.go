package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
)

// Typed cohort/revision columns keep time-window reads indexed. The versioned
// payload contains only the fixed, bounded RequestOutcomeRecord schema.
const requestOutcomesTableDDL = `CREATE TABLE IF NOT EXISTS request_outcomes (
 id BIGSERIAL UNIQUE,
 coord_request_id TEXT PRIMARY KEY CHECK (coord_request_id <> ''),
 received_at TIMESTAMPTZ NOT NULL,
 updated_at TIMESTAMPTZ NOT NULL,
 revision BIGINT NOT NULL,
 evidence_conflict BOOLEAN NOT NULL DEFAULT FALSE,
 record JSONB NOT NULL
)`

func (s *PostgresStore) RecordRequestOutcomes(ctx context.Context, records []RequestOutcomeRecord) error {
	for _, r := range records {
		if err := validateRequestOutcome(r); err != nil {
			return err
		}
	}
	if len(records) == 0 {
		return nil
	}
	// One transaction keeps a failed batch retryable; duplicate/stale snapshots
	// are harmless. Conflicting same-revision observations remain explicitly flagged.
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	batch := &pgx.Batch{}
	for _, r := range records {
		raw, err := json.Marshal(r)
		if err != nil {
			return err
		}
		batch.Queue(`INSERT INTO request_outcomes (coord_request_id,received_at,updated_at,revision,evidence_conflict,record)
  VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (coord_request_id) DO UPDATE SET
  evidence_conflict=request_outcomes.evidence_conflict OR EXCLUDED.evidence_conflict OR
    request_outcomes.received_at <> EXCLUDED.received_at OR
    request_outcomes.record->>'endpoint' <> EXCLUDED.record->>'endpoint' OR
    (request_outcomes.revision=EXCLUDED.revision AND (request_outcomes.record - 'evidence_conflict')<>(EXCLUDED.record - 'evidence_conflict')),
  updated_at=CASE WHEN EXCLUDED.revision>request_outcomes.revision THEN EXCLUDED.updated_at ELSE request_outcomes.updated_at END,
  record=CASE WHEN EXCLUDED.revision>request_outcomes.revision THEN EXCLUDED.record || jsonb_build_object('received_at',request_outcomes.record->'received_at','endpoint',request_outcomes.record->'endpoint') ELSE request_outcomes.record END,
  revision=GREATEST(request_outcomes.revision,EXCLUDED.revision)`, r.CoordRequestID, r.ReceivedAt, r.UpdatedAt, r.Revision, r.EvidenceConflict, raw)
	}
	results := tx.SendBatch(ctx, batch)
	if err := results.Close(); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *PostgresStore) RequestOutcomes(ctx context.Context, since, until time.Time, limit int) ([]RequestOutcomeRecord, error) {
	if limit <= 0 || limit > maxTelemetryReadRows {
		limit = maxTelemetryReadRows
	}
	rows, err := s.pool.Query(ctx, `SELECT record,evidence_conflict FROM request_outcomes WHERE received_at >= $1 AND received_at < $2 ORDER BY received_at,coord_request_id LIMIT $3`, since, until, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]RequestOutcomeRecord, 0)
	for rows.Next() {
		var raw []byte
		var conflict bool
		if err := rows.Scan(&raw, &conflict); err != nil {
			return nil, err
		}
		var r RequestOutcomeRecord
		if err := json.Unmarshal(raw, &r); err != nil {
			return nil, err
		}
		r.EvidenceConflict = r.EvidenceConflict || conflict
		out = append(out, r)
	}
	return out, rows.Err()
}
