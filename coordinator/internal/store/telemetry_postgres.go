package store

// Postgres-backed telemetry event storage.
//
// Inserts are batched via pgx's CopyFrom for throughput. Reads use the
// filter-translated WHERE clause and always ORDER BY ts DESC.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// InsertTelemetryEvents writes a batch into telemetry_events.
func (s *PostgresStore) InsertTelemetryEvents(ctx context.Context, events []TelemetryEventRecord) error {
	if len(events) == 0 {
		return nil
	}

	rows := make([][]any, 0, len(events))
	now := time.Now().UTC()
	for _, e := range events {
		fields := e.Fields
		if len(fields) == 0 {
			fields = json.RawMessage(`{}`)
		}
		received := e.ReceivedAt
		if received.IsZero() {
			received = now
		}
		rows = append(rows, []any{
			e.ID,
			e.Timestamp.UTC(),
			e.Source,
			e.Severity,
			e.Kind,
			e.Version,
			e.MachineID,
			e.AccountID,
			e.RequestID,
			e.SessionID,
			e.Message,
			fields,
			e.Stack,
			received,
		})
	}

	_, err := s.pool.CopyFrom(
		ctx,
		pgx.Identifier{"telemetry_events"},
		[]string{
			"id", "ts", "source", "severity", "kind", "version",
			"machine_id", "account_id", "request_id", "session_id",
			"message", "fields", "stack", "received_at",
		},
		pgx.CopyFromRows(rows),
	)
	if err != nil {
		return fmt.Errorf("store: insert telemetry: %w", err)
	}
	return nil
}

// ListTelemetryEvents returns events matching the filter, newest first.
func (s *PostgresStore) ListTelemetryEvents(ctx context.Context, f TelemetryFilter) ([]TelemetryEventRecord, error) {
	var (
		args  []any
		conds []string
	)
	add := func(sql string, v any) {
		args = append(args, v)
		conds = append(conds, fmt.Sprintf(sql, len(args)))
	}
	if f.Source != "" {
		add("source = $%d", f.Source)
	}
	if f.Severity != "" {
		add("severity = $%d", f.Severity)
	}
	if f.Kind != "" {
		add("kind = $%d", f.Kind)
	}
	if f.MachineID != "" {
		add("machine_id = $%d", f.MachineID)
	}
	if f.AccountID != "" {
		add("account_id = $%d", f.AccountID)
	}
	if f.RequestID != "" {
		add("request_id = $%d", f.RequestID)
	}
	if !f.Since.IsZero() {
		add("ts >= $%d", f.Since.UTC())
	}
	if !f.Until.IsZero() {
		add("ts <= $%d", f.Until.UTC())
	}

	where := ""
	if len(conds) > 0 {
		where = " WHERE " + strings.Join(conds, " AND ")
	}

	limit := f.Limit
	if limit <= 0 {
		limit = 100
	}
	if limit > 1000 {
		limit = 1000
	}
	args = append(args, limit)

	query := fmt.Sprintf(`SELECT id, ts, source, severity, kind, version,
			machine_id, account_id, request_id, session_id,
			message, fields, stack, received_at
		FROM telemetry_events
		%s
		ORDER BY ts DESC
		LIMIT $%d`, where, len(args))

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("store: query telemetry: %w", err)
	}
	defer rows.Close()

	out := make([]TelemetryEventRecord, 0, limit)
	for rows.Next() {
		var e TelemetryEventRecord
		if err := rows.Scan(
			&e.ID, &e.Timestamp, &e.Source, &e.Severity, &e.Kind, &e.Version,
			&e.MachineID, &e.AccountID, &e.RequestID, &e.SessionID,
			&e.Message, &e.Fields, &e.Stack, &e.ReceivedAt,
		); err != nil {
			return nil, fmt.Errorf("store: scan telemetry: %w", err)
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// DeleteTelemetryEventsOlderThan prunes rows older than the cutoff.
func (s *PostgresStore) DeleteTelemetryEventsOlderThan(ctx context.Context, before time.Time) (int64, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM telemetry_events WHERE ts < $1`, before.UTC())
	if err != nil {
		return 0, fmt.Errorf("store: prune telemetry: %w", err)
	}
	return tag.RowsAffected(), nil
}

// CountTelemetryEventsByKind aggregates for the admin dashboard.
func (s *PostgresStore) CountTelemetryEventsByKind(ctx context.Context, since time.Time) ([]TelemetryKindCount, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT source, severity, kind, COUNT(*)::bigint
		FROM telemetry_events
		WHERE ts >= $1
		GROUP BY source, severity, kind
		ORDER BY COUNT(*) DESC
		LIMIT 50`, since.UTC())
	if err != nil {
		return nil, fmt.Errorf("store: count telemetry: %w", err)
	}
	defer rows.Close()

	out := make([]TelemetryKindCount, 0, 32)
	for rows.Next() {
		var r TelemetryKindCount
		if err := rows.Scan(&r.Source, &r.Severity, &r.Kind, &r.Count); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
