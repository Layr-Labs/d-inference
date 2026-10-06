package retention

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const DefaultBatch = 5000

// Table names a prunable telemetry table and its time column. Only
// these two package constants are ever spliced into SQL text.
type Table struct {
	Name       string
	TimeColumn string
}

var (
	RequestProfiles = Table{Name: "request_profiles", TimeColumn: "created_at"}
	FleetSnapshots  = Table{Name: "fleet_snapshots", TimeColumn: "sampled_at"}
)

// pruneTelemetryTable deletes rows of t whose time column is before the cutoff
// and returns (deleted, rounds, err) where rounds is the number of DELETE
// transactions issued. A zero before, or no qualifying rows, is a no-op.
//
// cutoff = MAX(id) WHERE time < before is served by the time index; the sweep
// then walks [MIN(id), cutoff] in windows of batch ids. Postgres DELETE has no
// LIMIT, so the id window is what bounds each transaction. Every window runs
// with SET LOCAL lock_timeout = '2s' so a sweep can never queue behind a
// long-running query and stall the serving path.
func Prune(ctx context.Context, pool *pgxpool.Pool, t Table, before time.Time, batch int) (int, int, error) {
	if before.IsZero() {
		return 0, 0, nil
	}
	if batch <= 0 {
		batch = DefaultBatch
	}

	var cutoff *int64
	if err := pool.QueryRow(ctx,
		`SELECT MAX(id) FROM `+t.Name+` WHERE `+t.TimeColumn+` < $1`, before,
	).Scan(&cutoff); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, 0, nil // nothing expired
		}
		return 0, 0, fmt.Errorf("prune %s: cutoff: %w", t.Name, err)
	}
	if cutoff == nil {
		return 0, 0, nil
	}
	var lo *int64
	if err := pool.QueryRow(ctx,
		`SELECT MIN(id) FROM `+t.Name+` WHERE id <= $1`, *cutoff,
	).Scan(&lo); err != nil {
		return 0, 0, fmt.Errorf("prune %s: floor: %w", t.Name, err)
	}
	if lo == nil {
		return 0, 0, nil
	}

	deleted, rounds := 0, 0
	for cur := *lo; cur <= *cutoff; {
		if err := ctx.Err(); err != nil {
			return deleted, rounds, err
		}
		hi := cur + int64(batch)
		if hi > *cutoff+1 {
			hi = *cutoff + 1
		}
		n, err := deleteIDRange(ctx, pool, t, cur, hi, before)
		rounds++
		deleted += n
		if err != nil {
			return deleted, rounds, fmt.Errorf("prune %s [%d,%d): %w", t.Name, cur, hi, err)
		}
		cur = hi
	}
	return deleted, rounds, nil
}

// deleteTelemetryIDRange deletes ids in [lo, hi) from t in one transaction
// with a 2 s lock timeout and returns the rows removed.
func deleteIDRange(ctx context.Context, pool *pgxpool.Pool, t Table, lo, hi int64, before time.Time) (int, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `SET LOCAL lock_timeout = '2s'`); err != nil {
		return 0, err
	}
	// The time predicate guards a row that received a low id but a newer
	// timestamp (finalizers assign CreatedAt before the insert lands).
	tag, err := tx.Exec(ctx, `DELETE FROM `+t.Name+` WHERE id >= $1 AND id < $2 AND `+t.TimeColumn+` < $3`, lo, hi, before)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}
