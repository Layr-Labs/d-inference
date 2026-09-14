package schema

func routes() []string {
	return []string{

		// Inference routing telemetry — per-request scheduler decisions and outcomes.
		// Contains no prompt or response content.
		`CREATE TABLE IF NOT EXISTS inference_routes (
			id BIGSERIAL PRIMARY KEY,
			request_id TEXT NOT NULL,
			attempt INTEGER NOT NULL DEFAULT 0,
			provider_id TEXT NOT NULL DEFAULT '',
			model TEXT NOT NULL,
			public_model TEXT NOT NULL DEFAULT '',
			consumer_key_hash TEXT NOT NULL DEFAULT '',
			key_id TEXT NOT NULL DEFAULT '',
			outcome TEXT NOT NULL DEFAULT '',
			cost_ms DOUBLE PRECISION,
			state_ms DOUBLE PRECISION,
			queue_ms DOUBLE PRECISION,
			pending_ms DOUBLE PRECISION,
			backlog_ms DOUBLE PRECISION,
			this_req_ms DOUBLE PRECISION,
			health_ms DOUBLE PRECISION,
			ttft_ms DOUBLE PRECISION,
			best_ttft_ms DOUBLE PRECISION,
			effective_queue INTEGER,
			candidate_count INTEGER,
			capacity_rejections INTEGER,
			model_too_large_rejections INTEGER,
			vision_rejections INTEGER,
			ttft_rejections INTEGER,
			effective_tps DOUBLE PRECISION,
			static_tps DOUBLE PRECISION,
			provider_status TEXT,
			provider_trust_level TEXT,
			provider_version TEXT,
			hardware_chip TEXT,
			hardware_chip_family TEXT,
			hardware_tier TEXT,
			memory_gb INTEGER,
			gpu_cores INTEGER,
			cpu_cores INTEGER,
			system_memory_pressure DOUBLE PRECISION,
			system_cpu_usage DOUBLE PRECISION,
			system_thermal_state TEXT,
			gpu_memory_active_gb DOUBLE PRECISION,
			gpu_memory_peak_gb DOUBLE PRECISION,
			gpu_memory_cache_gb DOUBLE PRECISION,
			slot_state TEXT,
			backend_running INTEGER,
			backend_waiting INTEGER,
			active_token_budget_used BIGINT,
			active_token_budget_max BIGINT,
			queued_token_budget BIGINT,
			estimated_prompt_tokens INTEGER,
			requested_max_tokens INTEGER,
			requires_vision BOOLEAN NOT NULL DEFAULT FALSE,
			has_tools BOOLEAN NOT NULL DEFAULT FALSE,
			self_route_only BOOLEAN NOT NULL DEFAULT FALSE,
			prefer_owner BOOLEAN NOT NULL DEFAULT FALSE,
			cache_affinity_key TEXT NOT NULL DEFAULT '',
			final_status TEXT NOT NULL DEFAULT '',
			error_code INTEGER,
			error_class TEXT,
			prompt_tokens INTEGER,
			completion_tokens INTEGER,
			reasoning_tokens INTEGER,
			cost_micro_usd BIGINT,
			actual_ttft_ms DOUBLE PRECISION,
			dispatch_to_first_chunk_ms DOUBLE PRECISION,
			total_duration_ms DOUBLE PRECISION,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			provider_region TEXT,
			consumer_region TEXT,
			parse_ms DOUBLE PRECISION,
			reserve_ms DOUBLE PRECISION,
			route_ms DOUBLE PRECISION,
			encrypt_ms DOUBLE PRECISION,
			queue_wait_ms DOUBLE PRECISION,
			dispatch_ms DOUBLE PRECISION,
			actual_decode_tps DOUBLE PRECISION,
			admitted_but_failed BOOL,
			used_backup BOOL,
			backup_won BOOL,
			error_reason TEXT,
			UNIQUE(request_id, attempt)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_inference_routes_created ON inference_routes(created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_inference_routes_provider ON inference_routes(provider_id, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_inference_routes_model ON inference_routes(model, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_inference_routes_request ON inference_routes(request_id)`,
		`DO $$
		BEGIN
			IF NOT EXISTS (
				SELECT 1
				FROM pg_index i
				JOIN pg_class t ON t.oid = i.indrelid
				WHERE t.oid = 'inference_routes'::regclass
				  AND i.indisunique
				  AND ARRAY(
					SELECT a.attname::text
					FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
					JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
					ORDER BY k.ord
				  ) = ARRAY['request_id', 'attempt']
			) THEN
				CREATE UNIQUE INDEX idx_inference_routes_request_attempt_unique ON inference_routes(request_id, attempt);
			END IF;
		END $$`,
		// Phase 1 additions to inference_routes: coarse geo, coordinator-side
		// latency decomposition, measured decode TPS, and admission/backup-race
		// outcome flags. Added idempotently so a dev DB that already created the
		// Phase 0 table picks them up. New columns are appended AFTER updated_at
		// in the CREATE TABLE above so fresh and ALTER'd DBs share one column
		// order (InferenceRouteRecordsSince scans `SELECT *` positionally).
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS provider_region TEXT`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS consumer_region TEXT`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS parse_ms DOUBLE PRECISION`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS reserve_ms DOUBLE PRECISION`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS route_ms DOUBLE PRECISION`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS encrypt_ms DOUBLE PRECISION`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS queue_wait_ms DOUBLE PRECISION`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS dispatch_ms DOUBLE PRECISION`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS actual_decode_tps DOUBLE PRECISION`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS admitted_but_failed BOOL`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS used_backup BOOL`,
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS backup_won BOOL`,
		// DAR-341: normalized provider/coordinator error reason. Nullable and
		// appended so fresh DBs match upgraded DB column order for SELECT * scans.
		`ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS error_reason TEXT`,
		// Route keys are memory-only HMACs. Scrub legacy persisted SHA-256
		// prompt-cache identifiers once. The trigger also clears writes from an
		// older coordinator during blue-green overlap or emergency rollback while
		// retaining that binary's expected SQL shape.
		LegacyCacheAffinityGuardFunction,
		LegacyCacheAffinityGuardTrigger,
		LegacyCacheAffinityScrubMigration,
	}
}
