package schema

func providerOperations() []string {
	return []string{

		// Provider log reports — providers upload 24h unified logs for debugging.
		// serial_number is retained only as a rollback-compatible legacy column.
		// The write guard and one-time scrub keep it empty.
		`CREATE TABLE IF NOT EXISTS provider_log_reports (
			id BIGSERIAL PRIMARY KEY,
			serial_number TEXT NOT NULL DEFAULT '',
			provider_id TEXT NOT NULL DEFAULT '',
			account_id TEXT NOT NULL DEFAULT '',
			log_data BYTEA NOT NULL,
			log_size_bytes BIGINT NOT NULL DEFAULT 0,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`ALTER TABLE provider_log_reports ALTER COLUMN serial_number SET DEFAULT ''`,
		ProviderLogReportSerialGuardFunction,
		ProviderLogReportSerialGuardTrigger,
		ProviderLogReportSerialScrubMigration,
		`DROP INDEX IF EXISTS idx_log_reports_serial`,

		// Provider sessions — durable connect→disconnect history for uptime/downtime.
		// One row per websocket connection; disconnected_at IS NULL while open.
		// session_id is UNIQUE so the async open/close paths are order-independent
		// (open = INSERT ON CONFLICT DO NOTHING; close = upsert) — a fast
		// connect→disconnect where close races ahead of open cannot leave a
		// permanently-open row.
		`CREATE TABLE IF NOT EXISTS provider_sessions (
			id BIGSERIAL PRIMARY KEY,
			session_id TEXT NOT NULL UNIQUE,
			serial_number TEXT NOT NULL DEFAULT '',
			account_id TEXT NOT NULL DEFAULT '',
			connected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			disconnected_at TIMESTAMPTZ,
			disconnect_reason TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE INDEX IF NOT EXISTS idx_provider_sessions_serial ON provider_sessions(serial_number, connected_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_provider_sessions_connected ON provider_sessions(connected_at DESC)`,
		// Partial index over still-open sessions — speeds the online-now count and
		// the startup reconcile. (session_id lookups use the UNIQUE index.)
		`CREATE INDEX IF NOT EXISTS idx_provider_sessions_open ON provider_sessions(connected_at) WHERE disconnected_at IS NULL`,
	}
}
