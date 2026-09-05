package store

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/outcomes"
	"github.com/jackc/pgx/v5"
)

const requestOutcomesTableDDL = `CREATE TABLE IF NOT EXISTS request_outcomes (
 coord_request_id TEXT PRIMARY KEY CHECK (coord_request_id <> ''),
 schema_version INT NOT NULL, revision BIGINT NOT NULL,
 received_at TIMESTAMPTZ NOT NULL, finalized_at TIMESTAMPTZ, observed_at TIMESTAMPTZ NOT NULL,
 endpoint TEXT NOT NULL, stream BOOL, model TEXT NOT NULL,
 http_status INT, raw_reason TEXT NOT NULL, normalized_code TEXT NOT NULL,
 termination TEXT NOT NULL, response_progress TEXT NOT NULL, response_terminal TEXT NOT NULL, provider_outcome TEXT NOT NULL,
 content_egress_observed BOOL NOT NULL, client_write_error BOOL NOT NULL, response_egress_completed BOOL NOT NULL,
 client_departed BOOL NOT NULL, evidence_conflict BOOL NOT NULL, attempts_truncated BOOL NOT NULL,
 attempt_count INT NOT NULL, dispatched_attempt_count INT NOT NULL, deadline_refusal_count INT NOT NULL,
 attempts JSONB NOT NULL CHECK (jsonb_typeof(attempts) = 'array' AND jsonb_array_length(attempts) <= 64)
) WITH (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.02)`

var requestOutcomeUpsertSQL = buildRequestOutcomeUpsertSQL()

func buildRequestOutcomeUpsertSQL() string {
	columns := []string{"schema_version", "revision", "finalized_at", "observed_at", "stream", "model", "http_status", "raw_reason", "normalized_code", "termination", "response_progress", "response_terminal", "provider_outcome", "content_egress_observed", "client_write_error", "response_egress_completed", "client_departed", "attempts_truncated", "attempt_count", "dispatched_attempt_count", "deadline_refusal_count", "attempts"}
	parts := make([]string, 0, len(columns)+1)
	advance := "EXCLUDED.revision > request_outcomes.revision AND EXCLUDED.received_at = request_outcomes.received_at AND EXCLUDED.endpoint = request_outcomes.endpoint"
	for _, c := range columns {
		parts = append(parts, fmt.Sprintf("%s = CASE WHEN %s THEN EXCLUDED.%s ELSE request_outcomes.%s END", c, advance, c, c))
	}
	parts = append(parts, `evidence_conflict = request_outcomes.evidence_conflict OR EXCLUDED.evidence_conflict
 OR EXCLUDED.received_at <> request_outcomes.received_at OR EXCLUDED.endpoint <> request_outcomes.endpoint
 OR (EXCLUDED.revision = request_outcomes.revision AND
 (to_jsonb(EXCLUDED) - 'evidence_conflict') <> (to_jsonb(request_outcomes) - 'evidence_conflict'))`)
	return "INSERT INTO request_outcomes SELECT * FROM jsonb_populate_record(NULL::request_outcomes, $1::jsonb) ON CONFLICT (coord_request_id) DO UPDATE SET " + strings.Join(parts, ", ")
}

// Bounded pipelined writes preserve repeated keys' order inside a batch. A late
// older revision cannot overwrite terminal data; conflicting same revisions or
// reused IDs are flagged instead of selecting an arbitrary last row.
func (s *PostgresStore) RecordRequestOutcomes(records []*outcomes.Record) error {
	for start := 0; start < len(records); start += 64 {
		end := min(start+64, len(records))
		batch := &pgx.Batch{}
		for _, r := range records[start:end] {
			if r == nil {
				continue
			}
			encoded, err := encodeRequestOutcome(r)
			if err != nil {
				return err
			}
			batch.Queue(requestOutcomeUpsertSQL, encoded)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		result := s.pool.SendBatch(ctx, batch)
		err := result.Close()
		cancel()
		if err != nil {
			return fmt.Errorf("record request outcomes: %w", err)
		}
	}
	return nil
}

func (s *PostgresStore) RequestOutcomesBetween(ctx context.Context, from, to time.Time, limit int) ([]outcomes.Record, error) {
	rows, err := s.pool.Query(ctx, `SELECT to_jsonb(o) FROM request_outcomes o WHERE received_at >= $1 AND received_at < $2 ORDER BY received_at DESC, coord_request_id LIMIT $3`, from, to, outcomeReadLimit(limit))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []outcomes.Record{}
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var r outcomes.Record
		if err := json.Unmarshal(raw, &r); err != nil {
			return nil, err
		}
		result = append(result, r)
	}
	return result, rows.Err()
}

func (s *PostgresStore) PruneRequestOutcomes(ctx context.Context, before time.Time, batch int) (int, error) {
	if batch <= 0 || batch > 5000 {
		batch = 5000
	}
	tag, err := s.pool.Exec(ctx, `DELETE FROM request_outcomes WHERE coord_request_id IN (SELECT coord_request_id FROM request_outcomes WHERE received_at < $1 ORDER BY received_at LIMIT $2)`, before, batch)
	return int(tag.RowsAffected()), err
}
