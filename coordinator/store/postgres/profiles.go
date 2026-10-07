package postgres

import (
	"context"
	"fmt"
	"strings"
	"time"

	retention "github.com/eigeninference/d-inference/coordinator/internal/store/retention"

	profilesql "github.com/eigeninference/d-inference/coordinator/internal/store/profilesql"
	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// RecordRequestProfiles writes the records in bounded-shape multi-row INSERTs
// with ON CONFLICT (request_id, attempt) DO NOTHING. nil entries and empty
// input are skipped. Best-effort: callers log the error off the request path.
func (s *PostgresStore) RecordRequestProfiles(records []*store.RequestProfileRecord) error {
	live := make([]*store.RequestProfileRecord, 0, len(records))
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
	maxShape := profilesql.InsertShapes[len(profilesql.InsertShapes)-1]
	cols := len(profilesql.RequestColumns)
	for len(live) > 0 {
		n := min(len(live), maxShape)
		chunk := live[:n]
		live = live[n:]
		shape := profilesql.InsertShape(n)

		args := make([]any, 0, shape*cols)
		for _, r := range chunk {
			args = append(args, profilesql.RequestValues(r, orNow(r.CreatedAt, now))...)
		}
		last := chunk[n-1]
		for i := n; i < shape; i++ {
			args = append(args, profilesql.RequestValues(last, orNow(last.CreatedAt, now))...)
		}
		if _, err := s.pool.Exec(ctx, profilesql.InsertSQL(shape), args...); err != nil {
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

// RequestProfilesSinceFiltered returns profiles created at or after since,
// newest first, capped at maxTelemetryReadRows. The id tiebreak keeps
// same-instant rows in reverse insertion order (an incremental sort on the
// created_at index, not a full sort). It applies the admin predicates in the
// WHERE clause, before ORDER/LIMIT, so the read cap never hides a matching row.
func (s *PostgresStore) RequestProfilesSinceFiltered(since time.Time, filter store.RequestProfileFilter) []store.RequestProfileRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	where := []string{"created_at >= $1"}
	args := []any{since}
	add := func(clause string, v string) {
		args = append(args, v)
		where = append(where, fmt.Sprintf(clause, len(args)))
	}
	if filter.ProviderID != "" {
		add("provider_id = $%d", filter.ProviderID)
	}
	if filter.Model != "" {
		args = append(args, filter.Model)
		where = append(where, fmt.Sprintf("(model = $%d OR public_model = $%d)", len(args), len(args)))
	}
	if filter.FinalStatus != "" {
		add("final_status = $%d", filter.FinalStatus)
	}
	if filter.CoordRequestID != "" {
		add("coord_request_id = $%d", filter.CoordRequestID)
	}
	args = append(args, shared.MaxTelemetryReadRows)
	rows, err := s.pool.Query(ctx,
		`SELECT `+strings.Join(profilesql.RequestColumns, ", ")+
			` FROM request_profiles WHERE `+strings.Join(where, " AND ")+
			fmt.Sprintf(` ORDER BY created_at DESC, id DESC LIMIT $%d`, len(args)),
		args...)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []store.RequestProfileRecord
	for rows.Next() {
		var r store.RequestProfileRecord
		var gate, candidates, providerProfile []byte
		if err := rows.Scan(profilesql.RequestScanTargets(&r, &gate, &candidates, &providerProfile)...); err != nil {
			continue
		}
		r.GateRejections = shared.JsonbParam(gate)
		r.Candidates = shared.JsonbParam(candidates)
		r.ProviderProfile = shared.JsonbParam(providerProfile)
		records = append(records, r)
	}
	return records
}

// RecordFleetSnapshots bulk-loads one sampler tick with the COPY protocol.
// Empty input is a no-op. Best-effort: the sampler logs the error.
func (s *PostgresStore) RecordFleetSnapshots(rows []store.FleetSnapshotRow) error {
	if len(rows) == 0 {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	now := time.Now().UTC()
	src := pgx.CopyFromSlice(len(rows), func(i int) ([]any, error) {
		f := &rows[i]
		return profilesql.FleetValues(f, orNow(f.SampledAt, now)), nil
	})
	n, err := s.pool.CopyFrom(ctx, pgx.Identifier{"fleet_snapshots"}, profilesql.FleetColumns, src)
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
func (s *PostgresStore) FleetSnapshotsSince(since time.Time) []store.FleetSnapshotRow {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+strings.Join(profilesql.FleetColumns, ", ")+
			` FROM fleet_snapshots WHERE sampled_at >= $1 ORDER BY sampled_at DESC, id DESC LIMIT $2`,
		since, shared.MaxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var out []store.FleetSnapshotRow
	for rows.Next() {
		var f store.FleetSnapshotRow
		var queueDepthByModel []byte
		if err := rows.Scan(profilesql.FleetScanTargets(&f, &queueDepthByModel)...); err != nil {
			continue
		}
		f.QueueDepthByModel = shared.JsonbParam(queueDepthByModel)
		out = append(out, f)
	}
	return out
}

// PruneTelemetry runs the retention sweep for both profiler tables. Each
// table resolves one cutoff id through its time index, then deletes primary
// key windows of at most batch ids per short transaction so no single DELETE
// holds locks or bloats WAL for long. It stops at the first error or when ctx
// is done and returns the rows deleted so far.
func (s *PostgresStore) PruneTelemetry(ctx context.Context, profilesBefore, snapshotsBefore time.Time, batch int) (int, error) {
	total, _, err := retention.Prune(ctx, s.pool, retention.Table{Name: "request_outcomes", TimeColumn: "received_at"}, profilesBefore, batch)
	if err != nil {
		return total, err
	}
	n, _, err := retention.Prune(ctx, s.pool, retention.RequestProfiles, profilesBefore, batch)
	total += n
	if err != nil {
		return total, err
	}
	n, _, err = retention.Prune(ctx, s.pool, retention.FleetSnapshots, snapshotsBefore, batch)
	total += n
	return total, err
}
