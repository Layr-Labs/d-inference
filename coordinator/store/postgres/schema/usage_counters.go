package schema

func usageCounters() []string {
	return []string{

		// Telemetry events table + indices removed.
		// Datadog is the sole durable sink for telemetry — the Postgres table
		// was the single largest source of DB write pressure under provider load
		// (60 providers × batch/10s × 50 rows × 5 indexes = ~30-40% of the
		// connection pool). No read endpoints consumed this table.',

		// Materialized usage totals — eliminates full-table scan of usage
		// on every stats cache miss.  Single counter row incremented
		// atomically by RecordUsage / RecordUsageWithCostAndLocation.
		`CREATE TABLE IF NOT EXISTS usage_totals (
			id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
			total_requests BIGINT NOT NULL DEFAULT 0,
			total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
			total_completion_tokens BIGINT NOT NULL DEFAULT 0
		)`,

		// Partial index for UsageLocationBuckets — only rows with a
		// non-null request_location are ever queried.
		`CREATE INDEX IF NOT EXISTS idx_usage_request_location_notnull ON usage(created_at DESC) WHERE request_location IS NOT NULL`,
	}
}
