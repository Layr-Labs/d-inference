package postgres

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *PostgresStore) RecordAutopilot(ctx context.Context, records []store.AutopilotRecord) error {
	for _, r := range records {
		if err := shared.ValidateAutopilotRecord(r); err != nil {
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

func (s *PostgresStore) AutopilotRecords(ctx context.Context, since time.Time, limit int) ([]store.AutopilotRecord, error) {
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	rows, err := s.pool.Query(ctx, `SELECT record FROM autopilot_events WHERE at >= $1 ORDER BY at DESC,command_id LIMIT $2`, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []store.AutopilotRecord{}
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var r store.AutopilotRecord
		if err := json.Unmarshal(raw, &r); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
