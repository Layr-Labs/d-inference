package store

// Postgres telemetry storage — disabled.
//
// Datadog is the sole durable sink for telemetry events. The Postgres
// telemetry_events table + 5 indexes was the single largest source of DB
// write pressure (60 providers x 1 batch/10s = ~30 INSERTs/sec with 5
// index updates each, consuming ~30-40% of the connection pool).
//
// InsertTelemetryEvents is a no-op so the Store interface is satisfied.
// The in-memory store still buffers events for the admin metrics endpoint.

import "context"

// InsertTelemetryEvents is a no-op for PostgresStore. Telemetry events are
// forwarded to Datadog only; the in-memory ring buffer in MemoryStore
// handles test assertions and the admin metrics endpoint.
func (s *PostgresStore) InsertTelemetryEvents(_ context.Context, _ []TelemetryEventRecord) error {
	return nil
}
