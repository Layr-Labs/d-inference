package store

const sandboxActiveCommandConstraintMigration = `DO $migration$
	BEGIN
		WITH ranked AS (
			SELECT id,
				ROW_NUMBER() OVER (
					PARTITION BY sandbox_id
					ORDER BY created_at, id
				) AS active_rank
			FROM sandbox_commands
			WHERE state NOT IN (
				'succeeded', 'failed', 'timed_out', 'cancelled', 'lost'
			)
		)
		UPDATE sandbox_commands AS command
		SET state = 'lost',
			exit_code = NULL,
			stdout = '',
			stderr = '',
			output_truncated = FALSE,
			error_code = 'upgrade_concurrent_command',
			cancellation_pending = TRUE,
			completed_at = COALESCE(command.completed_at, CURRENT_TIMESTAMP),
			updated_at = GREATEST(command.updated_at, CURRENT_TIMESTAMP)
		FROM ranked
		WHERE command.id = ranked.id
		  AND ranked.active_rank > 1;
		IF EXISTS (
			SELECT 1
			FROM pg_indexes
			WHERE schemaname = current_schema()
			  AND indexname = 'idx_sandbox_commands_one_active'
			  AND indexdef LIKE '%cancellation_pending%'
		) THEN
			DROP INDEX idx_sandbox_commands_one_active;
		END IF;
		EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS
			idx_sandbox_commands_one_active
			ON sandbox_commands(sandbox_id)
			WHERE state NOT IN (
				''succeeded'', ''failed'', ''timed_out'', ''cancelled'', ''lost''
			)';
	END
	$migration$`

const sandboxActiveOperationConstraintMigration = `DO $migration$
	BEGIN
		IF EXISTS (
			SELECT 1
			FROM pg_indexes
			WHERE schemaname = current_schema()
			  AND indexname = 'idx_sandbox_operations_one_active'
			  AND indexdef NOT LIKE '%''queued''%'
		) THEN
			DROP INDEX idx_sandbox_operations_one_active;
		END IF;
		EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS
			idx_sandbox_operations_one_active
			ON sandbox_host_operations(sandbox_id)
			WHERE state NOT IN (
				''queued'', ''ready'', ''stopped'', ''deleted'', ''failed''
			)';
		EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS
			idx_sandbox_operations_one_queued
			ON sandbox_host_operations(sandbox_id)
			WHERE state = ''queued''';
	END
	$migration$`

func sandboxSchemaMigrations() []string {
	return []string{
		`CREATE TABLE IF NOT EXISTS sandboxes (
			id UUID PRIMARY KEY,
			account_id TEXT NOT NULL,
			created_by_key_id TEXT NOT NULL DEFAULT '',
			idempotency_key TEXT NOT NULL,
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
			termination_idempotency_key TEXT NOT NULL DEFAULT '',
			lease_expires_at TIMESTAMPTZ NOT NULL,
			error_code TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL
		)`,
		`ALTER TABLE sandboxes
			ADD COLUMN IF NOT EXISTS idempotency_key TEXT`,
		`DO $$
		BEGIN
			IF EXISTS (
				SELECT 1
				FROM information_schema.columns
				WHERE table_schema = current_schema()
				  AND table_name = 'sandboxes'
				  AND column_name = 'idempotency_key'
				  AND data_type <> 'text'
			) THEN
				ALTER TABLE sandboxes
					ALTER COLUMN idempotency_key TYPE TEXT
					USING idempotency_key::text;
			END IF;
		END $$`,
		`UPDATE sandboxes
			SET idempotency_key = id::text
			WHERE idempotency_key IS NULL OR idempotency_key = ''`,
		`ALTER TABLE sandboxes
			ALTER COLUMN idempotency_key SET NOT NULL`,
		`ALTER TABLE sandboxes
			ADD COLUMN IF NOT EXISTS termination_idempotency_key
			TEXT NOT NULL DEFAULT ''`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_sandboxes_account_idempotency
			ON sandboxes(account_id, idempotency_key)`,
		`CREATE INDEX IF NOT EXISTS idx_sandboxes_account_created
			ON sandboxes(account_id, created_at DESC)`,
		`DROP INDEX IF EXISTS idx_sandboxes_host_active`,
		`CREATE INDEX IF NOT EXISTS idx_sandboxes_host_nonterminal
			ON sandboxes(host_id, created_at)
			WHERE state <> 'deleted'`,

		`CREATE TABLE IF NOT EXISTS sandbox_host_operations (
			id UUID PRIMARY KEY,
			sandbox_id UUID NOT NULL REFERENCES sandboxes(id),
			account_id TEXT NOT NULL,
			idempotency_key TEXT NOT NULL,
			kind TEXT NOT NULL,
			state TEXT NOT NULL,
			generation BIGINT NOT NULL CHECK (generation > 0),
			fencing_token BIGINT NOT NULL CHECK (fencing_token > 0),
			requested_fencing_token BIGINT NOT NULL DEFAULT 0 CHECK (
				requested_fencing_token >= 0
			),
			previous_sandbox_state TEXT NOT NULL DEFAULT '',
			delete_after_stop BOOLEAN NOT NULL DEFAULT FALSE,
			requested_lease_expires_at TIMESTAMPTZ NOT NULL DEFAULT 'epoch',
			error_code TEXT NOT NULL DEFAULT '',
			dispatch_attempts INTEGER NOT NULL DEFAULT 0,
			last_dispatched_at TIMESTAMPTZ,
			last_dispatch_error TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL
		)`,
		`ALTER TABLE sandbox_host_operations
			ADD COLUMN IF NOT EXISTS idempotency_key TEXT`,
		`DO $$
		BEGIN
			IF EXISTS (
				SELECT 1
				FROM information_schema.columns
				WHERE table_schema = current_schema()
				  AND table_name = 'sandbox_host_operations'
				  AND column_name = 'idempotency_key'
				  AND data_type <> 'text'
			) THEN
				ALTER TABLE sandbox_host_operations
					ALTER COLUMN idempotency_key TYPE TEXT
					USING idempotency_key::text;
			END IF;
		END $$`,
		`UPDATE sandbox_host_operations
			SET idempotency_key = id::text
			WHERE idempotency_key IS NULL OR idempotency_key = ''`,
		`ALTER TABLE sandbox_host_operations
			ALTER COLUMN idempotency_key SET NOT NULL`,
		`ALTER TABLE sandbox_host_operations
			ADD COLUMN IF NOT EXISTS dispatch_attempts INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE sandbox_host_operations
			ADD COLUMN IF NOT EXISTS last_dispatched_at TIMESTAMPTZ`,
		`ALTER TABLE sandbox_host_operations
			ADD COLUMN IF NOT EXISTS last_dispatch_error TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE sandbox_host_operations
			ADD COLUMN IF NOT EXISTS requested_fencing_token
			BIGINT NOT NULL DEFAULT 0 CHECK (requested_fencing_token >= 0)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_sandbox_operations_idempotency
			ON sandbox_host_operations(account_id, sandbox_id, idempotency_key)`,
		`CREATE INDEX IF NOT EXISTS idx_sandbox_operations_sandbox_created
			ON sandbox_host_operations(sandbox_id, created_at DESC)`,
		sandboxActiveOperationConstraintMigration,

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
			dispatch_attempts INTEGER NOT NULL DEFAULT 0,
			last_dispatched_at TIMESTAMPTZ,
			last_dispatch_error TEXT NOT NULL DEFAULT '',
			cancellation_pending BOOLEAN NOT NULL DEFAULT FALSE,
			cancel_dispatch_attempts INTEGER NOT NULL DEFAULT 0,
			last_cancel_dispatched_at TIMESTAMPTZ,
			last_cancel_dispatch_error TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL,
			started_at TIMESTAMPTZ,
			completed_at TIMESTAMPTZ,
			updated_at TIMESTAMPTZ NOT NULL,
			UNIQUE (account_id, sandbox_id, idempotency_key)
		)`,
		`ALTER TABLE sandbox_commands
			ADD COLUMN IF NOT EXISTS dispatch_attempts INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE sandbox_commands
			ADD COLUMN IF NOT EXISTS last_dispatched_at TIMESTAMPTZ`,
		`ALTER TABLE sandbox_commands
			ADD COLUMN IF NOT EXISTS last_dispatch_error TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE sandbox_commands
			ADD COLUMN IF NOT EXISTS cancellation_pending
			BOOLEAN NOT NULL DEFAULT FALSE`,
		`ALTER TABLE sandbox_commands
			ADD COLUMN IF NOT EXISTS cancel_dispatch_attempts
			INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE sandbox_commands
			ADD COLUMN IF NOT EXISTS last_cancel_dispatched_at TIMESTAMPTZ`,
		`ALTER TABLE sandbox_commands
			ADD COLUMN IF NOT EXISTS last_cancel_dispatch_error
			TEXT NOT NULL DEFAULT ''`,
		`CREATE INDEX IF NOT EXISTS idx_sandbox_commands_sandbox_created
			ON sandbox_commands(sandbox_id, created_at DESC)`,
		sandboxActiveCommandConstraintMigration,
		`CREATE TABLE IF NOT EXISTS sandbox_host_fencing_sequences (
			host_id UUID PRIMARY KEY,
			next_token BIGINT NOT NULL CHECK (next_token > 0)
		)`,
		`INSERT INTO sandbox_host_fencing_sequences (host_id, next_token)
		 SELECT host_id,
		   CASE
		     WHEN MAX(fencing_token) >= 9223372036854775806
		     THEN 9223372036854775807
		     ELSE MAX(fencing_token) + 1
		   END
		 FROM (
		   SELECT host_id, fencing_token
		   FROM sandboxes
		   UNION ALL
		   SELECT sandboxes.host_id,
		     GREATEST(
		       sandbox_host_operations.fencing_token,
		       sandbox_host_operations.requested_fencing_token
		     )
		   FROM sandbox_host_operations
		   JOIN sandboxes
		     ON sandboxes.id = sandbox_host_operations.sandbox_id
		 ) AS issued_fences
		 GROUP BY host_id
		 ON CONFLICT (host_id) DO UPDATE
		 SET next_token = GREATEST(
		   sandbox_host_fencing_sequences.next_token,
		   EXCLUDED.next_token
		 )`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_sandboxes_host_fencing_token
			ON sandboxes(host_id, fencing_token)`,
	}
}
