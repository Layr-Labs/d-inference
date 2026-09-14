package schema

func bootstrap() []string {
	return []string{
		GlobalPayoutSchema,
		// schema_migrations records one-time data migrations that must run at most
		// once rather than on every boot. Idempotent DDL (CREATE/ALTER ... IF [NOT]
		// EXISTS) does not need this; it exists to gate destructive one-shot DML
		// cleanups (see the model_prices cleanup below) behind a marker id.
		`CREATE TABLE IF NOT EXISTS schema_migrations (
			id TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
	}
}
