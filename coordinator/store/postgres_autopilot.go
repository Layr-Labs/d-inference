package store

import (
	"context"
	"encoding/json"
	"time"
)

const autopilotDDL = `CREATE TABLE IF NOT EXISTS autopilot_events (
 command_id TEXT NOT NULL, phase TEXT NOT NULL, at TIMESTAMPTZ NOT NULL,
 record JSONB NOT NULL, PRIMARY KEY(command_id,phase)
); CREATE INDEX IF NOT EXISTS autopilot_events_at ON autopilot_events(at)`

func (s *PostgresStore) RecordAutopilot(ctx context.Context, records []AutopilotRecord) error {
	for _, r := range records {
		if err := validateAutopilotRecord(r); err != nil {
			return err
		}
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, r := range records {
		raw, _ := json.Marshal(r)
		if _, err := tx.Exec(ctx, `INSERT INTO autopilot_events(command_id,phase,at,record) VALUES($1,$2,$3,$4) ON CONFLICT(command_id,phase) DO NOTHING`, r.CommandID, r.Phase, r.At, raw); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
func (s *PostgresStore) AutopilotRecords(ctx context.Context, since time.Time, limit int) ([]AutopilotRecord, error) {
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	rows, err := s.pool.Query(ctx, `SELECT record FROM autopilot_events WHERE at >= $1 ORDER BY at DESC,command_id LIMIT $2`, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AutopilotRecord{}
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var r AutopilotRecord
		if err := json.Unmarshal(raw, &r); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
