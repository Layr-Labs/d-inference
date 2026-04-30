package store

// Postgres-backed telemetry event storage.
//
// Only InsertTelemetryEvents is kept for parity with the Store interface.
// Datadog handles durable persistence, querying, and retention. The Postgres
// write is best-effort secondary storage.

import (
	"context"
	"encoding/json"
	"fmt"
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
