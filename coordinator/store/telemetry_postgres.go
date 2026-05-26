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
	"strings"
	"time"
)

// InsertTelemetryEvents writes a batch into telemetry_events using INSERT with
// ON CONFLICT DO NOTHING so that duplicate event IDs from client retries are
// silently dropped instead of failing the entire batch.
func (s *PostgresStore) InsertTelemetryEvents(ctx context.Context, events []TelemetryEventRecord) error {
	if len(events) == 0 {
		return nil
	}

	now := time.Now().UTC()

	// Build a batch INSERT … ON CONFLICT (id) DO NOTHING.
	// Each row has 14 columns; placeholders are $1..$14, $15..$28, etc.
	const cols = 14
	var sb strings.Builder
	sb.WriteString(`INSERT INTO telemetry_events (
		id, ts, source, severity, kind, version,
		machine_id, account_id, request_id, session_id,
		message, fields, stack, received_at
	) VALUES `)

	args := make([]any, 0, len(events)*cols)
	for i, e := range events {
		if i > 0 {
			sb.WriteByte(',')
		}
		base := i * cols
		sb.WriteByte('(')
		for j := 0; j < cols; j++ {
			if j > 0 {
				sb.WriteByte(',')
			}
			fmt.Fprintf(&sb, "$%d", base+j+1)
		}
		sb.WriteByte(')')

		fields := e.Fields
		if len(fields) == 0 {
			fields = json.RawMessage(`{}`)
		}
		received := e.ReceivedAt
		if received.IsZero() {
			received = now
		}
		args = append(args,
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
		)
	}

	sb.WriteString(` ON CONFLICT (id) DO NOTHING`)

	_, err := s.pool.Exec(ctx, sb.String(), args...)
	if err != nil {
		return fmt.Errorf("store: insert telemetry: %w", err)
	}
	return nil
}
