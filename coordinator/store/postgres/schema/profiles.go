package schema

func profiles() []string {
	return []string{

		// System profiler (docs/reports request-profiler plan §2.1/§2.4): two NEW
		// append-only telemetry tables, no ALTER on any existing table. The DDL
		// text lives in the request/fleet constants below so tests can pin the Go
		// column lists to it. Both tables are created empty on first boot, so the
		// plain CREATE INDEX statements never lock a populated table; any FUTURE
		// index on these tables must be built CONCURRENTLY outside this loop
		// (see ensureProviderEarningsJobIndex). The request_waterfall view is NOT
		// here — it is applied by hand from store/migrations/request_waterfall.sql.
		RequestOutcomesTableDDL,
		`CREATE INDEX IF NOT EXISTS idx_request_outcomes_received ON request_outcomes (received_at, coord_request_id)`,
		RequestProfilesTableDDL,
		RequestProfilesCreatedIndexDDL,
		RequestProfilesCoordIndexDDL,
		RequestProfilesProviderIndexDDL,
		FleetSnapshotsTableDDL,
		FleetSnapshotsSampledIndexDDL,
		// request_profiles / fleet_snapshots are profiler-only and cold (never
		// hot-path locked), so idempotent ADD COLUMN IF NOT EXISTS is safe here;
		// it upgrades a database that first booted at 02832be21 (before the
		// request-shape columns) or before the fleet capability columns. Only
		// duplicate_column (two coordinators racing the same ALTER) is swallowed;
		// any other failure aborts boot so a half-migrated schema is never served.
		`DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS estimated_prompt_tokens INT NOT NULL DEFAULT 0; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS requested_max_tokens INT NOT NULL DEFAULT 0; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS requires_vision BOOL NOT NULL DEFAULT FALSE; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS has_tools BOOL NOT NULL DEFAULT FALSE; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS predictive_bypass TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS reservation_ttft_ceiling_ms DOUBLE PRECISION; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS dispatch_budget_ms BIGINT; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE fleet_snapshots ADD COLUMN IF NOT EXISTS provider_version TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		// free_for_load_gb became nullable (nil = provider did not report it); idempotent.
		`ALTER TABLE fleet_snapshots ALTER COLUMN free_for_load_gb DROP NOT NULL`,
		`DO $$ BEGIN ALTER TABLE fleet_snapshots ADD COLUMN IF NOT EXISTS model_vision BOOL NOT NULL DEFAULT FALSE; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE fleet_snapshots ADD COLUMN IF NOT EXISTS template_render_ok BOOL; EXCEPTION WHEN duplicate_column THEN NULL; END $$`,
		FleetSnapshotsProviderIndexDDL,
	}
}
