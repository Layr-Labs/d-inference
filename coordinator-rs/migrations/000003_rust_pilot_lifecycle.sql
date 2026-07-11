-- Durable pilot review journal and authorized-attempt uniqueness.
--
-- coordinator-rs/migrations/000003_rust_pilot_lifecycle.sql is a byte-for-byte
-- mirror. Serving startup never executes this DDL.

DO $$
BEGIN
    IF (
        SELECT COUNT(*)
        FROM rust_coord.schema_versions
    ) <> 2 OR NOT EXISTS (
        SELECT 1
        FROM rust_coord.schema_versions
        WHERE version = 2
          AND minimum_public_schema_version = 4
          AND maximum_public_schema_version = 4
    ) THEN
        RAISE EXCEPTION
            'rust_coord schema must be at version 2 before pilot lifecycle migration';
    END IF;
END $$;

ALTER TABLE rust_coord.inference_jobs
    ADD COLUMN consumer_key_hash TEXT NOT NULL DEFAULT '',
    ADD COLUMN input_micro_usd_per_million BIGINT
        CHECK (input_micro_usd_per_million >= 0),
    ADD COLUMN output_micro_usd_per_million BIGINT
        CHECK (output_micro_usd_per_million >= 0),
    ADD COLUMN provider_share_ppm INTEGER
        CHECK (provider_share_ppm BETWEEN 0 AND 1000000),
    ADD COLUMN start_authorized_at TIMESTAMPTZ,
    ADD COLUMN start_deadline TIMESTAMPTZ,
    ADD CONSTRAINT inference_jobs_start_window_check CHECK (
        (start_authorized_at IS NULL AND start_deadline IS NULL)
        OR (
            start_authorized_at IS NOT NULL
            AND start_deadline IS NOT NULL
            AND start_deadline > start_authorized_at
        )
    );

-- Legacy pilot rows did not always persist their absolute request deadline.
-- Active rows without one must be immediately recoverable rather than retain
-- a reservation indefinitely.
UPDATE rust_coord.inference_jobs
SET request_deadline = NOW()
WHERE request_deadline IS NULL;

ALTER TABLE rust_coord.inference_jobs
    ALTER COLUMN request_deadline SET NOT NULL;

UPDATE rust_coord.inference_attempts
SET state = 'queued'
WHERE state = 'queued_to_socket';

ALTER TABLE rust_coord.inference_attempts
    DROP CONSTRAINT inference_attempts_state_check,
    ALTER COLUMN state SET DEFAULT 'not_sent',
    ADD CONSTRAINT inference_attempts_state_check CHECK (
        state IN (
            'not_sent',
            'queued',
            'on_wire',
            'sent_unknown',
            'prepared',
            'started',
            'terminal_recorded',
            'aborted',
            'acknowledged'
        )
    );

UPDATE rust_coord.inference_jobs
SET
    accepted_chunk_sequence = COALESCE(accepted_chunk_sequence, 0),
    accepted_cumulative_tokens = COALESCE(accepted_cumulative_tokens, 0);

ALTER TABLE rust_coord.inference_jobs
    ALTER COLUMN accepted_chunk_sequence SET DEFAULT 0,
    ALTER COLUMN accepted_chunk_sequence SET NOT NULL,
    ALTER COLUMN accepted_cumulative_tokens SET DEFAULT 0,
    ALTER COLUMN accepted_cumulative_tokens SET NOT NULL;

ALTER TABLE rust_coord.provider_terminals
    DROP CONSTRAINT provider_terminals_conflict_check,
    ADD CONSTRAINT provider_terminals_conflict_check CHECK (
        NOT conflict OR status IN (
            'conflict',
            'settled',
            'released',
            'settled_reviewed',
            'released_reviewed'
        )
    );

CREATE TABLE rust_coord.review_resolution_journal (
    resolution_id UUID PRIMARY KEY,
    job_id UUID NOT NULL,
    disposition TEXT NOT NULL
        CHECK (disposition IN ('settled_reviewed', 'released_reviewed')),
    operator_reason TEXT NOT NULL
        CHECK (
            operator_reason <> ''
            AND operator_reason = btrim(operator_reason)
            AND octet_length(operator_reason) <= 4096
        ),
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT review_resolution_journal_job_fk
        FOREIGN KEY (job_id)
        REFERENCES rust_coord.inference_jobs (job_id)
        ON DELETE RESTRICT,
    UNIQUE (job_id)
);

CREATE INDEX idx_rust_review_resolution_created
    ON rust_coord.review_resolution_journal (created_at DESC);

DROP INDEX IF EXISTS rust_coord.idx_rust_attempts_one_started_per_job;
CREATE UNIQUE INDEX idx_rust_attempts_one_authorized_per_job
    ON rust_coord.inference_attempts (job_id)
    WHERE state IN (
        'not_sent',
        'queued',
        'on_wire',
        'sent_unknown',
        'started',
        'terminal_recorded',
        'acknowledged'
    );

DROP INDEX IF EXISTS rust_coord.idx_rust_attempts_live_provider;
CREATE INDEX idx_rust_attempts_live_provider
    ON rust_coord.inference_attempts (provider_id, updated_at)
    WHERE state IN (
        'not_sent',
        'queued',
        'on_wire',
        'sent_unknown',
        'prepared',
        'started',
        'terminal_recorded'
    );

DROP INDEX IF EXISTS rust_coord.idx_rust_jobs_recovery;
CREATE INDEX idx_rust_jobs_recovery
    ON rust_coord.inference_jobs (state, request_deadline, updated_at)
    WHERE state IN (
        'reserved',
        'preparing',
        'prepared',
        'start_authorized',
        'running'
    );

INSERT INTO rust_coord.schema_versions (
    version,
    minimum_public_schema_version,
    maximum_public_schema_version
)
VALUES (3, 5, 5);

DO $$
BEGIN
    IF (
        SELECT COUNT(*)
        FROM rust_coord.schema_versions
    ) <> 3 OR NOT EXISTS (
        SELECT 1
        FROM rust_coord.schema_versions
        WHERE version = 3
          AND minimum_public_schema_version = 5
          AND maximum_public_schema_version = 5
    ) THEN
        RAISE EXCEPTION
            'rust_coord schema version 3 compatibility metadata is incompatible';
    END IF;
END $$;
