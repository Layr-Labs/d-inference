package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

const earningsSummaryMarkerTimeout = 5 * time.Second

// The planning transaction retains its pinned snapshot on the only leased pool
// connection. A separate short-lived connection commits the uncertainty marker,
// avoiding a second pool acquisition that would deadlock a one-connection pool.
// The caller's migration advisory lock bounds this to one extra connection per
// database while the first plan is created; ready plans never call this method.
func (s *PostgresStore) claimEarningsSummaryAttempt(ctx context.Context) (bool, error) {
	markerCtx, cancel := context.WithTimeout(ctx, earningsSummaryMarkerTimeout)
	defer cancel()
	cfg := s.pool.Config().ConnConfig.Copy()
	if cfg.ConnectTimeout == 0 || cfg.ConnectTimeout > earningsSummaryMarkerTimeout {
		cfg.ConnectTimeout = earningsSummaryMarkerTimeout
	}
	conn, err := pgx.ConnectConfig(markerCtx, cfg)
	if err != nil {
		return false, fmt.Errorf("connect earnings marker writer: %w", err)
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 2*time.Second)
		defer stop()
		_ = conn.Close(cleanup)
	}()
	tag, err := conn.Exec(markerCtx, `INSERT INTO schema_migrations(id) VALUES($1) ON CONFLICT(id) DO NOTHING`, earningsSummaryPlanAttemptID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}
