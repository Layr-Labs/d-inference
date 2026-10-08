package postgres

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

var _ store.MachineAutopilotStore = (*PostgresStore)(nil)

func (s *PostgresStore) ListMachineAutopilotSettings(ctx context.Context, after string, limit int) ([]store.MachineAutopilotSetting, error) {
	if limit <= 0 {
		limit = 100
	} else if limit > 200 {
		limit = 200
	}
	rows, err := s.pool.Query(ctx, `SELECT id,autopilot_desired_mode,autopilot_revision
	 FROM darkbloom_machines WHERE merged_into IS NULL AND id > $1 ORDER BY id LIMIT $2`, after, limit)
	if err != nil {
		return nil, err
	}
	return scanMachineAutopilotSettings(rows)
}

func (s *PostgresStore) LiveMachineAutopilotSettings(ctx context.Context) ([]store.MachineAutopilotSetting, error) {
	rows, err := s.pool.Query(ctx, `SELECT id,autopilot_desired_mode,autopilot_revision
	 FROM darkbloom_machines WHERE merged_into IS NULL AND autopilot_desired_mode='live' ORDER BY id`)
	if err != nil {
		return nil, err
	}
	return scanMachineAutopilotSettings(rows)
}

func (s *PostgresStore) SetMachineAutopilotDesiredMode(ctx context.Context, machineID string, mode store.MachineAutopilotMode) (store.MachineAutopilotSetting, error) {
	if err := ctx.Err(); err != nil {
		return store.MachineAutopilotSetting{}, err
	}
	if mode != store.MachineAutopilotShadow && mode != store.MachineAutopilotLive {
		return store.MachineAutopilotSetting{}, store.ErrInvalidMachineAutopilotMode
	}
	var setting store.MachineAutopilotSetting
	err := s.pool.QueryRow(ctx, `UPDATE darkbloom_machines
	 SET autopilot_revision=autopilot_revision + CASE WHEN autopilot_desired_mode <> $2 THEN 1 ELSE 0 END,
	     autopilot_desired_mode=$2
	 WHERE id=$1 AND merged_into IS NULL
	 RETURNING id,autopilot_desired_mode,autopilot_revision`, machineID, mode).
		Scan(&setting.MachineID, &setting.DesiredMode, &setting.Revision)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.MachineAutopilotSetting{}, store.ErrNotFound
	}
	return setting, err
}

func scanMachineAutopilotSettings(rows pgx.Rows) ([]store.MachineAutopilotSetting, error) {
	defer rows.Close()
	settings := make([]store.MachineAutopilotSetting, 0)
	for rows.Next() {
		var setting store.MachineAutopilotSetting
		if err := rows.Scan(&setting.MachineID, &setting.DesiredMode, &setting.Revision); err != nil {
			return nil, err
		}
		settings = append(settings, setting)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return settings, nil
}
