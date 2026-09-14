package schema

func modelRegistry() []string {
	return []string{

		// The legacy admin-managed supported_models catalog was replaced by the
		// manifest-backed model_registry below. Drop the stale duplicate table if
		// it is still present from an older deployment.
		`DROP TABLE IF EXISTS supported_models`,

		`CREATE TABLE IF NOT EXISTS model_registry (
			id TEXT PRIMARY KEY,
			display_name TEXT NOT NULL,
			family TEXT NOT NULL DEFAULT '',
			architecture TEXT NOT NULL DEFAULT '',
			quantization TEXT NOT NULL DEFAULT '',
			max_context_length INTEGER NOT NULL DEFAULT 0,
			max_output_length INTEGER NOT NULL DEFAULT 0,
			min_ram_gb INTEGER NOT NULL DEFAULT 0,
			capabilities TEXT[] NOT NULL DEFAULT '{}',
			required_provider_capabilities TEXT[] NOT NULL DEFAULT '{}',
			status TEXT NOT NULL DEFAULT 'beta',
			description TEXT NOT NULL DEFAULT '',
			runtime_parameters JSONB NOT NULL DEFAULT '{}',
			metadata JSONB NOT NULL DEFAULT '{}',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_model_registry_status ON model_registry(status)`,
		`CREATE TABLE IF NOT EXISTS model_versions (
			id BIGSERIAL PRIMARY KEY,
			model_id TEXT NOT NULL REFERENCES model_registry(id) ON DELETE CASCADE,
			version TEXT NOT NULL,
			r2_prefix TEXT NOT NULL,
			aggregate_sha256 TEXT NOT NULL,
			total_size_bytes BIGINT NOT NULL,
			file_count INTEGER NOT NULL,
			status TEXT NOT NULL DEFAULT 'ready',
			uploaded_by TEXT NOT NULL DEFAULT '',
			uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			promoted_at TIMESTAMPTZ,
			metadata JSONB NOT NULL DEFAULT '{}',
			UNIQUE(model_id, version)
		)`,
		`ALTER TABLE model_versions ADD COLUMN IF NOT EXISTS hugging_face_artifact JSONB`,
		`DO $$ BEGIN
			ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS max_context_length INTEGER NOT NULL DEFAULT 0;
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS max_output_length INTEGER NOT NULL DEFAULT 0;
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS runtime_parameters JSONB NOT NULL DEFAULT '{}';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS required_provider_capabilities TEXT[] NOT NULL DEFAULT '{}';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`UPDATE model_registry
		 SET required_provider_capabilities = (
		   SELECT ARRAY_AGG(DISTINCT capability ORDER BY capability)
		   FROM UNNEST(required_provider_capabilities ||
		     ARRAY['apple_m5', 'mlx_nax']::TEXT[]) AS capability
		 )
		 WHERE id = 'EigenLabs/Qwen3.8-27B-4bit'
		   AND NOT (required_provider_capabilities @>
		     ARRAY['apple_m5', 'mlx_nax']::TEXT[])`,
		`CREATE INDEX IF NOT EXISTS idx_model_versions_model ON model_versions(model_id)`,
		`CREATE TABLE IF NOT EXISTS model_version_files (
			id BIGSERIAL PRIMARY KEY,
			model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE CASCADE,
			path TEXT NOT NULL,
			size_bytes BIGINT NOT NULL,
			sha256 TEXT NOT NULL,
			role TEXT NOT NULL,
			UNIQUE(model_version_id, path)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_model_version_files_version ON model_version_files(model_version_id)`,
		`CREATE TABLE IF NOT EXISTS model_active_versions (
			model_id TEXT PRIMARY KEY REFERENCES model_registry(id) ON DELETE CASCADE,
			model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE RESTRICT,
			activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS publishing_api_keys (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			key_hash TEXT NOT NULL,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_used_at TIMESTAMPTZ
		)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_api_keys_hash ON publishing_api_keys(key_hash)`,

		// Model aliases (public-facing names → a desired concrete build). An alias
		// resolves to a single desired_build (the build providers converge to) with
		// an optional previous_build that stays acceptable during a rollout. Lets us
		// swap the underlying quant (fp8 → qat-4bit) behind a stable consumer-facing
		// model name. The legacy `builds` JSONB column is kept (nullable, default
		// '[]') only so an older coordinator binary doesn't choke on the table; it
		// is no longer read or written — drop it in a follow-up release.
		`CREATE TABLE IF NOT EXISTS model_aliases (
			alias_id TEXT PRIMARY KEY,
			display_name TEXT NOT NULL DEFAULT '',
			builds JSONB NOT NULL DEFAULT '[]'::jsonb,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		// Declarative desired/previous build pointers (additive migration).
		`DO $$ BEGIN ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS desired_build TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS previous_build TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		// Alias lineage: former desired/previous builds rotated out by later
		// upserts, so a provider returning from a long offline period is still
		// recognized as part of the alias's fleet.
		`DO $$ BEGIN ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS retired_builds JSONB NOT NULL DEFAULT '[]'::jsonb; EXCEPTION WHEN others THEN NULL; END $$`,
		// OpenRouter-only aliases clone an existing public alias or concrete model
		// while keeping an independent API id and marketplace identities. Existing
		// rows predate source_kind and therefore retain standard-alias semantics.
		`DO $$ BEGIN ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS openrouter_only BOOLEAN NOT NULL DEFAULT FALSE; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS source_model TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS source_kind TEXT NOT NULL DEFAULT 'standard_alias'; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS openrouter_slug TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS hugging_face_id TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,

		// Backfill desired_build from the old `builds` JSON: pick the highest-weight
		// active build of each alias that hasn't been migrated yet. DISTINCT ON keeps
		// exactly one (highest-weight) build per alias so the UPDATE...FROM join is
		// deterministic. One-shot; safe to re-run because it only touches rows still
		// on the empty default.
		`DO $$ BEGIN
			UPDATE model_aliases a
			SET desired_build = sub.build_id
			FROM (
				SELECT DISTINCT ON (alias_id) alias_id, (b->>'build_id') AS build_id
				FROM model_aliases, jsonb_array_elements(builds) AS b
				WHERE COALESCE((b->>'active')::boolean, true)
				  AND COALESCE((b->>'weight')::int, 0) > 0
				ORDER BY alias_id, COALESCE((b->>'weight')::int, 0) DESC
			) sub
			WHERE a.alias_id = sub.alias_id AND a.desired_build = '';
		EXCEPTION WHEN others THEN NULL; END $$`,
		// The weighted-ramp migration controller is gone; drop its table.
		`DROP TABLE IF EXISTS model_migrations`,
	}
}
