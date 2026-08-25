package store

func sandboxSchemaMigrations() []string {
	return []string{
		`CREATE TABLE IF NOT EXISTS sandboxes (
			id UUID PRIMARY KEY,
			account_id TEXT NOT NULL,
			created_by_key_id TEXT NOT NULL DEFAULT '',
			host_id UUID NOT NULL,
			generation BIGINT NOT NULL CHECK (generation > 0),
			fencing_token BIGINT NOT NULL CHECK (fencing_token > 0),
			base_image_id TEXT NOT NULL,
			cpu_count SMALLINT NOT NULL CHECK (cpu_count > 0),
			memory_bytes BIGINT NOT NULL CHECK (memory_bytes > 0),
			workspace_bytes BIGINT NOT NULL CHECK (workspace_bytes > 0),
			command_timeout_seconds INTEGER NOT NULL CHECK (
				command_timeout_seconds > 0
			),
			gpu BOOLEAN NOT NULL DEFAULT FALSE,
			state TEXT NOT NULL,
			termination_requested BOOLEAN NOT NULL DEFAULT FALSE,
			lease_expires_at TIMESTAMPTZ NOT NULL,
			error_code TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sandboxes_account_created
			ON sandboxes(account_id, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_sandboxes_host_active
			ON sandboxes(host_id, created_at)
			WHERE state NOT IN ('deleted', 'failed')`,

		`CREATE TABLE IF NOT EXISTS sandbox_host_operations (
			id UUID PRIMARY KEY,
			sandbox_id UUID NOT NULL REFERENCES sandboxes(id),
			account_id TEXT NOT NULL,
			kind TEXT NOT NULL,
			state TEXT NOT NULL,
			generation BIGINT NOT NULL CHECK (generation > 0),
			fencing_token BIGINT NOT NULL CHECK (fencing_token > 0),
			previous_sandbox_state TEXT NOT NULL DEFAULT '',
			delete_after_stop BOOLEAN NOT NULL DEFAULT FALSE,
			requested_lease_expires_at TIMESTAMPTZ NOT NULL DEFAULT 'epoch',
			error_code TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sandbox_operations_sandbox_created
			ON sandbox_host_operations(sandbox_id, created_at DESC)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_sandbox_operations_one_active
			ON sandbox_host_operations(sandbox_id)
			WHERE state NOT IN ('ready', 'stopped', 'deleted', 'failed')`,

		`CREATE TABLE IF NOT EXISTS sandbox_commands (
			id UUID PRIMARY KEY,
			sandbox_id UUID NOT NULL REFERENCES sandboxes(id),
			account_id TEXT NOT NULL,
			idempotency_key TEXT NOT NULL,
			generation BIGINT NOT NULL CHECK (generation > 0),
			fencing_token BIGINT NOT NULL CHECK (fencing_token > 0),
			arguments JSONB NOT NULL,
			environment JSONB NOT NULL DEFAULT 'null'::jsonb,
			working_directory TEXT NOT NULL DEFAULT '',
			timeout_seconds INTEGER NOT NULL CHECK (
				timeout_seconds > 0 AND timeout_seconds <= 900
			),
			state TEXT NOT NULL,
			exit_code INTEGER,
			stdout TEXT NOT NULL DEFAULT '',
			stderr TEXT NOT NULL DEFAULT '',
			output_truncated BOOLEAN NOT NULL DEFAULT FALSE,
			error_code TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL,
			started_at TIMESTAMPTZ,
			completed_at TIMESTAMPTZ,
			updated_at TIMESTAMPTZ NOT NULL,
			UNIQUE (account_id, sandbox_id, idempotency_key)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sandbox_commands_sandbox_created
			ON sandbox_commands(sandbox_id, created_at DESC)`,
	}
}
