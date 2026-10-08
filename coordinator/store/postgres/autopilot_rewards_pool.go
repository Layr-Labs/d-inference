package postgres

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) AutopilotRewardPool(ctx context.Context) (earningsfloor.Pool, error) {
	var pool earningsfloor.Pool
	err := s.pool.QueryRow(ctx, `SELECT cap_micro_usd,spent_micro_usd,tracking_started_at FROM autopilot_reward_pool WHERE singleton`).
		Scan(&pool.CapMicroUSD, &pool.SpentMicroUSD, &pool.TrackingStartedAt)
	return pool, err
}

func (s *PostgresStore) SetAutopilotRewardPoolCap(ctx context.Context, capMicroUSD int64) (earningsfloor.Pool, error) {
	if capMicroUSD < 0 {
		return earningsfloor.Pool{}, earningsfloor.ErrPoolCap
	}
	var pool earningsfloor.Pool
	err := s.pool.QueryRow(ctx, `UPDATE autopilot_reward_pool SET cap_micro_usd=$1
	 WHERE singleton AND spent_micro_usd<=$1 RETURNING cap_micro_usd,spent_micro_usd,tracking_started_at`, capMicroUSD).
		Scan(&pool.CapMicroUSD, &pool.SpentMicroUSD, &pool.TrackingStartedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		err = earningsfloor.ErrPoolCap
	}
	return pool, err
}

func lockAutopilotRewardPool(ctx context.Context, tx pgx.Tx) (earningsfloor.Pool, error) {
	var pool earningsfloor.Pool
	err := tx.QueryRow(ctx, `SELECT cap_micro_usd,spent_micro_usd,tracking_started_at FROM autopilot_reward_pool WHERE singleton FOR UPDATE`).
		Scan(&pool.CapMicroUSD, &pool.SpentMicroUSD, &pool.TrackingStartedAt)
	return pool, err
}
