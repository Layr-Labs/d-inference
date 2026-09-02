package store

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// profileInsertShapes are the only multi-row INSERT arities ever sent for
// request_profiles, so the per-connection prepared-statement cache holds at
// most three distinct statements. Input is chunked to the largest shape and
// each chunk is padded (by repeating its last row) up to the next shape;
// padded duplicates are absorbed by ON CONFLICT DO NOTHING inside the same
// statement. Skipped rows still consume BIGSERIAL values, so ids can have
// gaps — harmless: the retention sweep walks id ranges bounded by the time
// index and never assumes density.
var profileInsertShapes = [...]int{1, 8, 64}

// defaultTelemetryPruneBatch is the per-transaction DELETE window used when
// PruneTelemetry is called with batch <= 0.
const defaultTelemetryPruneBatch = 5000

var (
	profileInsertSQLOnce sync.Once
	profileInsertSQL     map[int]string
)

// requestProfileInsertSQL returns the cached multi-row INSERT for shape rows.
func requestProfileInsertSQL(shape int) string {
	profileInsertSQLOnce.Do(func() {
		profileInsertSQL = make(map[int]string, len(profileInsertShapes))
		for _, n := range profileInsertShapes {
			profileInsertSQL[n] = buildRequestProfileInsertSQL(n)
		}
	})
	return profileInsertSQL[shape]
}

// buildRequestProfileInsertSQL renders
//
//	INSERT INTO request_profiles (<cols>) VALUES ($1,...),($n+1,...) ON CONFLICT (request_id, attempt) DO NOTHING
//
// with numbered placeholders for rows rows.
func buildRequestProfileInsertSQL(rows int) string {
	cols := len(requestProfileColumns)
	var b strings.Builder
	b.Grow(96 + cols*28 + rows*cols*6)
	b.WriteString("INSERT INTO request_profiles (")
	b.WriteString(strings.Join(requestProfileColumns, ", "))
	b.WriteString(") VALUES ")
	p := 1
	for r := 0; r < rows; r++ {
		if r > 0 {
			b.WriteString(", ")
		}
		b.WriteByte('(')
		for c := 0; c < cols; c++ {
			if c > 0 {
				b.WriteByte(',')
			}
			b.WriteByte('$')
			b.WriteString(strconv.Itoa(p))
			p++
		}
		b.WriteByte(')')
	}
	b.WriteString(" ON CONFLICT (request_id, attempt) DO NOTHING")
	return b.String()
}

// profileInsertShape returns the smallest shape that fits n rows
// (1 <= n <= profileInsertShapes[last]).
func profileInsertShape(n int) int {
	for _, s := range profileInsertShapes {
		if n <= s {
			return s
		}
	}
	return profileInsertShapes[len(profileInsertShapes)-1]
}

// RecordRequestProfiles writes the records in bounded-shape multi-row INSERTs
// with ON CONFLICT (request_id, attempt) DO NOTHING. nil entries and empty
// input are skipped. Best-effort: callers log the error off the request path.
func (s *PostgresStore) RecordRequestProfiles(records []*RequestProfileRecord) error {
	live := make([]*RequestProfileRecord, 0, len(records))
	for _, r := range records {
		if r != nil {
			live = append(live, r)
		}
	}
	if len(live) == 0 {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	now := time.Now().UTC()
	maxShape := profileInsertShapes[len(profileInsertShapes)-1]
	cols := len(requestProfileColumns)
	for len(live) > 0 {
		n := min(len(live), maxShape)
		chunk := live[:n]
		live = live[n:]
		shape := profileInsertShape(n)

		args := make([]any, 0, shape*cols)
		for _, r := range chunk {
			args = append(args, requestProfileValues(r, orNow(r.CreatedAt, now))...)
		}
		last := chunk[n-1]
		for i := n; i < shape; i++ {
			args = append(args, requestProfileValues(last, orNow(last.CreatedAt, now))...)
		}
		if _, err := s.pool.Exec(ctx, requestProfileInsertSQL(shape), args...); err != nil {
			return fmt.Errorf("record request profiles (%d rows): %w", n, err)
		}
	}
	return nil
}

func orNow(t, now time.Time) time.Time {
	if t.IsZero() {
		return now
	}
	return t
}

// RequestProfilesSince returns profiles created at or after since, newest
// first, capped at maxTelemetryReadRows. The id tiebreak keeps same-instant
// rows in reverse insertion order (an incremental sort on the created_at
// index, not a full sort).
func (s *PostgresStore) RequestProfilesSince(since time.Time) []RequestProfileRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+strings.Join(requestProfileColumns, ", ")+
			` FROM request_profiles WHERE created_at >= $1 ORDER BY created_at DESC, id DESC LIMIT $2`,
		since, maxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []RequestProfileRecord
	for rows.Next() {
		var r RequestProfileRecord
		var gate, candidates, providerProfile []byte
		if err := rows.Scan(requestProfileScanTargets(&r, &gate, &candidates, &providerProfile)...); err != nil {
			continue
		}
		r.GateRejections = jsonbParam(gate)
		r.Candidates = jsonbParam(candidates)
		r.ProviderProfile = jsonbParam(providerProfile)
		records = append(records, r)
	}
	return records
}

// RecordFleetSnapshots bulk-loads one sampler tick with the COPY protocol.
// Empty input is a no-op. Best-effort: the sampler logs the error.
func (s *PostgresStore) RecordFleetSnapshots(rows []FleetSnapshotRow) error {
	if len(rows) == 0 {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	now := time.Now().UTC()
	src := pgx.CopyFromSlice(len(rows), func(i int) ([]any, error) {
		f := &rows[i]
		return fleetSnapshotValues(f, orNow(f.SampledAt, now)), nil
	})
	n, err := s.pool.CopyFrom(ctx, pgx.Identifier{"fleet_snapshots"}, fleetSnapshotColumns, src)
	if err != nil {
		return fmt.Errorf("record fleet snapshots: %w", err)
	}
	if n != int64(len(rows)) {
		return fmt.Errorf("record fleet snapshots: copied %d of %d rows", n, len(rows))
	}
	return nil
}

// FleetSnapshotsSince returns snapshot rows sampled at or after since, newest
// first (id tiebreak within a tick), capped at maxTelemetryReadRows.
func (s *PostgresStore) FleetSnapshotsSince(since time.Time) []FleetSnapshotRow {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+strings.Join(fleetSnapshotColumns, ", ")+
			` FROM fleet_snapshots WHERE sampled_at >= $1 ORDER BY sampled_at DESC, id DESC LIMIT $2`,
		since, maxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var out []FleetSnapshotRow
	for rows.Next() {
		var f FleetSnapshotRow
		var queueDepthByModel []byte
		if err := rows.Scan(fleetSnapshotScanTargets(&f, &queueDepthByModel)...); err != nil {
			continue
		}
		f.QueueDepthByModel = jsonbParam(queueDepthByModel)
		out = append(out, f)
	}
	return out
}

// telemetryTable names a prunable telemetry table and its time column. Only
// these two package constants are ever spliced into SQL text.
type telemetryTable struct {
	name    string
	timeCol string
}

var (
	requestProfilesTable = telemetryTable{name: "request_profiles", timeCol: "created_at"}
	fleetSnapshotsTable  = telemetryTable{name: "fleet_snapshots", timeCol: "sampled_at"}
)

// PruneTelemetry runs the retention sweep for both profiler tables. Each
// table resolves one cutoff id through its time index, then deletes primary
// key windows of at most batch ids per short transaction so no single DELETE
// holds locks or bloats WAL for long. It stops at the first error or when ctx
// is done and returns the rows deleted so far.
func (s *PostgresStore) PruneTelemetry(ctx context.Context, profilesBefore, snapshotsBefore time.Time, batch int) (int, error) {
	total := 0
	n, _, err := s.pruneTelemetryTable(ctx, requestProfilesTable, profilesBefore, batch)
	total += n
	if err != nil {
		return total, err
	}
	n, _, err = s.pruneTelemetryTable(ctx, fleetSnapshotsTable, snapshotsBefore, batch)
	total += n
	return total, err
}

// pruneTelemetryTable deletes rows of t whose time column is before the cutoff
// and returns (deleted, rounds, err) where rounds is the number of DELETE
// transactions issued. A zero before, or no qualifying rows, is a no-op.
//
// cutoff = MAX(id) WHERE time < before is served by the time index; the sweep
// then walks [MIN(id), cutoff] in windows of batch ids. Postgres DELETE has no
// LIMIT, so the id window is what bounds each transaction. Every window runs
// with SET LOCAL lock_timeout = '2s' so a sweep can never queue behind a
// long-running query and stall the serving path.
func (s *PostgresStore) pruneTelemetryTable(ctx context.Context, t telemetryTable, before time.Time, batch int) (int, int, error) {
	if before.IsZero() {
		return 0, 0, nil
	}
	if batch <= 0 {
		batch = defaultTelemetryPruneBatch
	}

	var cutoff *int64
	if err := s.pool.QueryRow(ctx,
		`SELECT MAX(id) FROM `+t.name+` WHERE `+t.timeCol+` < $1`, before,
	).Scan(&cutoff); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, 0, nil // nothing expired
		}
		return 0, 0, fmt.Errorf("prune %s: cutoff: %w", t.name, err)
	}
	if cutoff == nil {
		return 0, 0, nil
	}
	var lo *int64
	if err := s.pool.QueryRow(ctx,
		`SELECT MIN(id) FROM `+t.name+` WHERE id <= $1`, *cutoff,
	).Scan(&lo); err != nil {
		return 0, 0, fmt.Errorf("prune %s: floor: %w", t.name, err)
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
		n, err := s.deleteTelemetryIDRange(ctx, t, cur, hi, before)
		rounds++
		deleted += n
		if err != nil {
			return deleted, rounds, fmt.Errorf("prune %s [%d,%d): %w", t.name, cur, hi, err)
		}
		cur = hi
	}
	return deleted, rounds, nil
}

// deleteTelemetryIDRange deletes ids in [lo, hi) from t in one transaction
// with a 2 s lock timeout and returns the rows removed.
func (s *PostgresStore) deleteTelemetryIDRange(ctx context.Context, t telemetryTable, lo, hi int64, before time.Time) (int, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `SET LOCAL lock_timeout = '2s'`); err != nil {
		return 0, err
	}
	// The time predicate guards a row that received a low id but a newer
	// timestamp (finalizers assign CreatedAt before the insert lands).
	tag, err := tx.Exec(ctx, `DELETE FROM `+t.name+` WHERE id >= $1 AND id < $2 AND `+t.timeCol+` < $3`, lo, hi, before)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}
