-- Canonical additive durable schema for the Rust coordinator.
--
-- coordinator-rs/migrations/000002_rust_durable_schema.sql is a byte-for-byte
-- mirror. Change this public migration first, copy it exactly, and keep the
-- mirror invariant test green. Serving startup never executes this DDL.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM rust_coord.schema_versions
        WHERE version = 1
          AND minimum_public_schema_version = 3
          AND maximum_public_schema_version = 3
    ) OR EXISTS (
        SELECT 1
        FROM rust_coord.schema_versions
        WHERE NOT (
            version = 1
            AND minimum_public_schema_version = 3
            AND maximum_public_schema_version = 3
        ) AND NOT (
            version = 2
            AND minimum_public_schema_version = 4
            AND maximum_public_schema_version = 4
        )
    ) THEN
        RAISE EXCEPTION
            'rust_coord schema history is not the supported v1/v2 history';
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS rust_coord.inference_jobs (
    job_id UUID PRIMARY KEY,
    request_id UUID NOT NULL UNIQUE,
    reservation_id UUID NOT NULL UNIQUE,
    reserve_operation_key TEXT NOT NULL UNIQUE
        CHECK (reserve_operation_key <> ''),
    account_id TEXT NOT NULL CHECK (account_id <> ''),
    api_key_id TEXT NOT NULL DEFAULT '',
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    state TEXT NOT NULL DEFAULT 'reserved'
        CONSTRAINT inference_jobs_state_check CHECK (state IN (
            'reserved',
            'preparing',
            'prepared',
            'start_authorized',
            'running',
            'settled',
            'released',
            'review_pending',
            'settled_reviewed',
            'released_reviewed'
        )),
    reserved_total_micro_usd BIGINT NOT NULL
        CHECK (reserved_total_micro_usd >= 0),
    reserved_withdrawable_micro_usd BIGINT NOT NULL
        CHECK (
            reserved_withdrawable_micro_usd >= 0
            AND reserved_withdrawable_micro_usd <= reserved_total_micro_usd
        ),
    reservation_pre_debited BOOLEAN NOT NULL,
    concrete_model TEXT,
    public_model TEXT,
    pricing_version BIGINT CHECK (pricing_version > 0),
    rounding_version BIGINT CHECK (rounding_version > 0),
    billable_input_tokens BIGINT CHECK (billable_input_tokens >= 0),
    bounded_output_tokens BIGINT CHECK (bounded_output_tokens >= 0),
    provider_id UUID,
    provider_account_id TEXT,
    platform_account_id TEXT NOT NULL DEFAULT 'platform'
        CHECK (platform_account_id <> ''),
    referral_account_id TEXT,
    provider_payout_micro_usd BIGINT
        CHECK (provider_payout_micro_usd >= 0),
    platform_fee_micro_usd BIGINT
        CHECK (platform_fee_micro_usd >= 0),
    referral_reward_micro_usd BIGINT
        CHECK (referral_reward_micro_usd >= 0),
    referral_share_ppm BIGINT
        CHECK (referral_share_ppm BETWEEN 0 AND 1000000),
    request_digest BYTEA CHECK (octet_length(request_digest) = 32),
    accepted_chunk_sequence BIGINT
        CHECK (accepted_chunk_sequence >= 0),
    accepted_cumulative_tokens BIGINT
        CHECK (accepted_cumulative_tokens >= 0),
    first_content_deadline TIMESTAMPTZ,
    request_deadline TIMESTAMPTZ,
    outcome TEXT CHECK (outcome IN ('completed', 'cancelled', 'error')),
    error_class TEXT,
    usage_prompt_tokens BIGINT CHECK (usage_prompt_tokens >= 0),
    usage_completion_tokens BIGINT CHECK (usage_completion_tokens >= 0),
    usage_reasoning_tokens BIGINT CHECK (usage_reasoning_tokens >= 0),
    response_digest BYTEA CHECK (octet_length(response_digest) = 32),
    worker_owner UUID,
    lease_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    terminal_at TIMESTAMPTZ,
    CONSTRAINT inference_jobs_worker_lease_check CHECK (
        (worker_owner IS NULL) = (lease_until IS NULL)
    ),
    CONSTRAINT inference_jobs_deadline_order_check CHECK (
        first_content_deadline IS NULL
        OR request_deadline IS NULL
        OR first_content_deadline <= request_deadline
    ),
    CONSTRAINT inference_jobs_referral_terms_check CHECK (
        (
            referral_account_id IS NULL
            AND COALESCE(referral_reward_micro_usd, 0) = 0
            AND COALESCE(referral_share_ppm, 0) = 0
        )
        OR (
            referral_account_id IS NOT NULL
            AND referral_account_id <> ''
            AND referral_reward_micro_usd IS NOT NULL
            AND referral_share_ppm IS NOT NULL
        )
    ),
    CONSTRAINT inference_jobs_frozen_terms_check CHECK (
        state NOT IN (
            'start_authorized',
            'running',
            'settled',
            'settled_reviewed'
        )
        OR (
            concrete_model IS NOT NULL
            AND concrete_model <> ''
            AND public_model IS NOT NULL
            AND public_model <> ''
            AND pricing_version IS NOT NULL
            AND rounding_version IS NOT NULL
            AND billable_input_tokens IS NOT NULL
            AND bounded_output_tokens IS NOT NULL
            AND provider_id IS NOT NULL
            AND provider_account_id IS NOT NULL
            AND provider_account_id <> ''
            AND provider_payout_micro_usd IS NOT NULL
            AND platform_fee_micro_usd IS NOT NULL
            AND request_digest IS NOT NULL
        )
    ),
    CONSTRAINT inference_jobs_terminal_time_check CHECK (
        (
            state IN (
                'settled',
                'released',
                'settled_reviewed',
                'released_reviewed'
            )
        ) = (terminal_at IS NOT NULL)
    ),
    CONSTRAINT inference_jobs_timestamp_order_check CHECK (
        updated_at >= created_at
        AND (terminal_at IS NULL OR terminal_at >= created_at)
    )
);

CREATE INDEX IF NOT EXISTS idx_rust_jobs_active_account
    ON rust_coord.inference_jobs (account_id, created_at)
    WHERE state IN (
        'reserved',
        'preparing',
        'prepared',
        'start_authorized',
        'running',
        'review_pending'
    );
CREATE INDEX IF NOT EXISTS idx_rust_jobs_active_api_key
    ON rust_coord.inference_jobs (api_key_id, created_at)
    WHERE api_key_id <> '' AND state IN (
        'reserved',
        'preparing',
        'prepared',
        'start_authorized',
        'running',
        'review_pending'
    );
CREATE INDEX IF NOT EXISTS idx_rust_jobs_recovery
    ON rust_coord.inference_jobs (state, updated_at)
    WHERE state IN (
        'reserved',
        'preparing',
        'prepared',
        'start_authorized',
        'running',
        'review_pending'
    );
CREATE INDEX IF NOT EXISTS idx_rust_jobs_worker_lease
    ON rust_coord.inference_jobs (lease_until)
    WHERE worker_owner IS NOT NULL;

CREATE TABLE IF NOT EXISTS rust_coord.inference_attempts (
    attempt_id UUID PRIMARY KEY,
    job_id UUID NOT NULL,
    provider_id UUID NOT NULL,
    provider_process_generation_id UUID NOT NULL,
    session_epoch BIGINT NOT NULL CHECK (session_epoch > 0),
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    lease_id UUID,
    permit_id UUID NOT NULL,
    dispatch_nonce BYTEA NOT NULL
        CHECK (octet_length(dispatch_nonce) = 32),
    request_digest BYTEA NOT NULL
        CHECK (octet_length(request_digest) = 32),
    kind TEXT NOT NULL
        CONSTRAINT inference_attempts_kind_check CHECK (
            kind IN ('primary', 'alternate', 'hedge')
        ),
    state TEXT NOT NULL DEFAULT 'queued_to_socket'
        CONSTRAINT inference_attempts_state_check CHECK (state IN (
            'queued_to_socket',
            'sent_unknown',
            'prepared',
            'started',
            'terminal_recorded',
            'aborted',
            'acknowledged'
        )),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    worker_owner UUID,
    lease_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT inference_attempts_job_fk
        FOREIGN KEY (job_id)
        REFERENCES rust_coord.inference_jobs (job_id)
        ON DELETE RESTRICT,
    CONSTRAINT inference_attempts_worker_lease_check CHECK (
        (worker_owner IS NULL) = (lease_until IS NULL)
    ),
    CONSTRAINT inference_attempts_prepared_lease_check CHECK (
        state NOT IN (
            'prepared',
            'started',
            'terminal_recorded',
            'acknowledged'
        )
        OR lease_id IS NOT NULL
    ),
    CONSTRAINT inference_attempts_timestamp_order_check CHECK (
        updated_at >= created_at
    ),
    UNIQUE (
        job_id,
        attempt_id,
        provider_id,
        provider_process_generation_id,
        session_epoch
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_rust_attempts_lease
    ON rust_coord.inference_attempts (lease_id)
    WHERE lease_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_rust_attempts_one_started_per_job
    ON rust_coord.inference_attempts (job_id)
    WHERE state IN ('started', 'terminal_recorded', 'acknowledged');
CREATE INDEX IF NOT EXISTS idx_rust_attempts_job
    ON rust_coord.inference_attempts (job_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rust_attempts_live_provider
    ON rust_coord.inference_attempts (provider_id, updated_at)
    WHERE state IN (
        'queued_to_socket',
        'sent_unknown',
        'prepared',
        'started',
        'terminal_recorded'
    );
CREATE INDEX IF NOT EXISTS idx_rust_attempts_worker_lease
    ON rust_coord.inference_attempts (lease_until)
    WHERE worker_owner IS NOT NULL;

CREATE TABLE IF NOT EXISTS rust_coord.provider_terminals (
    terminal_id UUID PRIMARY KEY,
    job_id UUID NOT NULL,
    attempt_id UUID NOT NULL,
    provider_id UUID NOT NULL,
    provider_process_generation_id UUID NOT NULL,
    origin_session_epoch BIGINT NOT NULL CHECK (origin_session_epoch > 0),
    terminal_digest BYTEA NOT NULL UNIQUE
        CHECK (octet_length(terminal_digest) = 32),
    raw_terminal JSONB NOT NULL
        CHECK (jsonb_typeof(raw_terminal) = 'object'),
    outcome TEXT NOT NULL
        CONSTRAINT provider_terminals_outcome_check CHECK (
            outcome IN ('completed', 'cancelled', 'error')
        ),
    error_class TEXT,
    prompt_tokens BIGINT NOT NULL CHECK (prompt_tokens >= 0),
    completion_tokens BIGINT NOT NULL CHECK (completion_tokens >= 0),
    reasoning_tokens BIGINT NOT NULL DEFAULT 0
        CHECK (reasoning_tokens >= 0),
    response_digest BYTEA NOT NULL
        CHECK (octet_length(response_digest) = 32),
    rolling_digest BYTEA NOT NULL
        CHECK (octet_length(rolling_digest) = 32),
    final_generated_tokens BIGINT NOT NULL
        CHECK (final_generated_tokens >= 0),
    provider_signature BYTEA NOT NULL
        CHECK (octet_length(provider_signature) > 0),
    status TEXT NOT NULL DEFAULT 'pending'
        CONSTRAINT provider_terminals_status_check CHECK (status IN (
            'pending',
            'settled',
            'released',
            'settled_reviewed',
            'released_reviewed',
            'duplicate',
            'late',
            'rejected',
            'conflict'
        )),
    conflict BOOLEAN NOT NULL DEFAULT FALSE,
    received_count INTEGER NOT NULL DEFAULT 1 CHECK (received_count > 0),
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    worker_owner UUID,
    lease_until TIMESTAMPTZ,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    disposition_at TIMESTAMPTZ,
    CONSTRAINT provider_terminals_attempt_fk
        FOREIGN KEY (
            job_id,
            attempt_id,
            provider_id,
            provider_process_generation_id,
            origin_session_epoch
        )
        REFERENCES rust_coord.inference_attempts (
            job_id,
            attempt_id,
            provider_id,
            provider_process_generation_id,
            session_epoch
        )
        ON DELETE RESTRICT,
    CONSTRAINT provider_terminals_worker_lease_check CHECK (
        (worker_owner IS NULL) = (lease_until IS NULL)
    ),
    CONSTRAINT provider_terminals_conflict_check CHECK (
        NOT conflict OR status = 'conflict'
    ),
    CONSTRAINT provider_terminals_disposition_time_check CHECK (
        (status = 'pending') = (disposition_at IS NULL)
    ),
    CONSTRAINT provider_terminals_timestamp_order_check CHECK (
        updated_at >= received_at
        AND (disposition_at IS NULL OR disposition_at >= received_at)
    ),
    UNIQUE (attempt_id, terminal_digest)
);

CREATE INDEX IF NOT EXISTS idx_rust_terminals_pending
    ON rust_coord.provider_terminals (received_at)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_rust_terminals_conflict
    ON rust_coord.provider_terminals (received_at)
    WHERE conflict;
CREATE INDEX IF NOT EXISTS idx_rust_terminals_job
    ON rust_coord.provider_terminals (job_id, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_rust_terminals_worker_lease
    ON rust_coord.provider_terminals (lease_until)
    WHERE worker_owner IS NOT NULL;

CREATE TABLE IF NOT EXISTS rust_coord.financial_operations (
    operation_id UUID PRIMARY KEY,
    operation_key TEXT NOT NULL UNIQUE CHECK (operation_key <> ''),
    operation_digest BYTEA NOT NULL UNIQUE
        CHECK (octet_length(operation_digest) = 32),
    kind TEXT NOT NULL
        CONSTRAINT financial_operations_kind_check CHECK (kind IN (
            'reserve',
            'resize',
            'settle',
            'release',
            'deposit',
            'withdrawal_intent',
            'withdrawal_complete',
            'withdrawal_refund',
            'fee_projection'
        )),
    status TEXT NOT NULL DEFAULT 'pending'
        CONSTRAINT financial_operations_status_check CHECK (
            status IN ('pending', 'applied', 'released', 'failed')
        ),
    job_id UUID,
    terminal_id UUID,
    account_id TEXT NOT NULL CHECK (account_id <> ''),
    counterparty_account_id TEXT,
    amount_total_micro_usd BIGINT NOT NULL,
    amount_withdrawable_micro_usd BIGINT NOT NULL,
    result JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(result) = 'object'),
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    worker_owner UUID,
    lease_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    CONSTRAINT financial_operations_job_fk
        FOREIGN KEY (job_id)
        REFERENCES rust_coord.inference_jobs (job_id)
        ON DELETE RESTRICT,
    CONSTRAINT financial_operations_terminal_fk
        FOREIGN KEY (terminal_id)
        REFERENCES rust_coord.provider_terminals (terminal_id)
        ON DELETE RESTRICT,
    CONSTRAINT financial_operations_job_kind_check CHECK (
        kind NOT IN ('reserve', 'resize', 'settle', 'release')
        OR job_id IS NOT NULL
    ),
    CONSTRAINT financial_operations_settle_terminal_check CHECK (
        kind <> 'settle' OR terminal_id IS NOT NULL
    ),
    CONSTRAINT financial_operations_provenance_check CHECK (
        abs(amount_withdrawable_micro_usd::numeric)
        <= abs(amount_total_micro_usd::numeric)
    ),
    CONSTRAINT financial_operations_worker_lease_check CHECK (
        (worker_owner IS NULL) = (lease_until IS NULL)
    ),
    CONSTRAINT financial_operations_completion_time_check CHECK (
        (status = 'pending') = (completed_at IS NULL)
    ),
    CONSTRAINT financial_operations_timestamp_order_check CHECK (
        updated_at >= created_at
        AND (completed_at IS NULL OR completed_at >= created_at)
    )
);

CREATE INDEX IF NOT EXISTS idx_rust_financial_operations_job
    ON rust_coord.financial_operations (job_id, created_at)
    WHERE job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rust_financial_operations_account
    ON rust_coord.financial_operations (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rust_financial_operations_pending
    ON rust_coord.financial_operations (created_at)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_rust_financial_operations_worker_lease
    ON rust_coord.financial_operations (lease_until)
    WHERE worker_owner IS NOT NULL;

CREATE TABLE IF NOT EXISTS rust_coord.external_events (
    external_event_id UUID PRIMARY KEY,
    source TEXT NOT NULL CHECK (source <> ''),
    event_id TEXT NOT NULL CHECK (event_id <> ''),
    event_kind TEXT NOT NULL CHECK (event_kind <> ''),
    payload_digest BYTEA NOT NULL
        CHECK (octet_length(payload_digest) = 32),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(payload) = 'object'),
    status TEXT NOT NULL DEFAULT 'pending'
        CONSTRAINT external_events_status_check CHECK (status IN (
            'pending',
            'processing',
            'applied',
            'rejected',
            'ignored',
            'failed'
        )),
    financial_operation_id UUID UNIQUE,
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    worker_owner UUID,
    lease_until TIMESTAMPTZ,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    CONSTRAINT external_events_financial_operation_fk
        FOREIGN KEY (financial_operation_id)
        REFERENCES rust_coord.financial_operations (operation_id)
        ON DELETE RESTRICT,
    CONSTRAINT external_events_worker_lease_check CHECK (
        (worker_owner IS NULL) = (lease_until IS NULL)
    ),
    CONSTRAINT external_events_processed_time_check CHECK (
        (status IN ('pending', 'processing')) = (processed_at IS NULL)
    ),
    CONSTRAINT external_events_timestamp_order_check CHECK (
        updated_at >= received_at
        AND (processed_at IS NULL OR processed_at >= received_at)
    ),
    UNIQUE (source, event_id)
);

CREATE INDEX IF NOT EXISTS idx_rust_external_events_pending
    ON rust_coord.external_events (received_at)
    WHERE status IN ('pending', 'processing');
CREATE INDEX IF NOT EXISTS idx_rust_external_events_source
    ON rust_coord.external_events (source, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_rust_external_events_worker_lease
    ON rust_coord.external_events (lease_until)
    WHERE worker_owner IS NOT NULL;

CREATE TABLE IF NOT EXISTS rust_coord.outbox (
    outbox_id UUID PRIMARY KEY,
    operation_key TEXT NOT NULL UNIQUE CHECK (operation_key <> ''),
    payload_digest BYTEA NOT NULL
        CHECK (octet_length(payload_digest) = 32),
    kind TEXT NOT NULL
        CONSTRAINT outbox_kind_check CHECK (kind IN (
            'external_call',
            'fee_projection',
            'legacy_projection',
            'notification',
            'telemetry'
        )),
    status TEXT NOT NULL DEFAULT 'pending'
        CONSTRAINT outbox_status_check CHECK (status IN (
            'pending',
            'processing',
            'delivered',
            'failed',
            'cancelled'
        )),
    job_id UUID,
    financial_operation_id UUID,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(payload) = 'object'),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts INTEGER NOT NULL DEFAULT 10 CHECK (max_attempts > 0),
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    worker_owner UUID,
    lease_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivered_at TIMESTAMPTZ,
    CONSTRAINT outbox_job_fk
        FOREIGN KEY (job_id)
        REFERENCES rust_coord.inference_jobs (job_id)
        ON DELETE RESTRICT,
    CONSTRAINT outbox_financial_operation_fk
        FOREIGN KEY (financial_operation_id)
        REFERENCES rust_coord.financial_operations (operation_id)
        ON DELETE RESTRICT,
    CONSTRAINT outbox_attempt_bound_check CHECK (attempts <= max_attempts),
    CONSTRAINT outbox_worker_lease_check CHECK (
        (worker_owner IS NULL) = (lease_until IS NULL)
    ),
    CONSTRAINT outbox_delivery_time_check CHECK (
        (status = 'delivered') = (delivered_at IS NOT NULL)
    ),
    CONSTRAINT outbox_timestamp_order_check CHECK (
        updated_at >= created_at
        AND (delivered_at IS NULL OR delivered_at >= created_at)
    )
);

CREATE INDEX IF NOT EXISTS idx_rust_outbox_pending
    ON rust_coord.outbox (next_attempt_at)
    WHERE status IN ('pending', 'processing');
CREATE INDEX IF NOT EXISTS idx_rust_outbox_job
    ON rust_coord.outbox (job_id, created_at DESC)
    WHERE job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rust_outbox_worker_lease
    ON rust_coord.outbox (lease_until)
    WHERE worker_owner IS NOT NULL;

CREATE TABLE IF NOT EXISTS rust_coord.fee_allocations (
    allocation_id UUID PRIMARY KEY,
    allocation_sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    operation_key TEXT NOT NULL UNIQUE CHECK (operation_key <> ''),
    job_id UUID NOT NULL,
    financial_operation_id UUID NOT NULL,
    kind TEXT NOT NULL
        CONSTRAINT fee_allocations_kind_check CHECK (
            kind IN ('platform', 'referral')
        ),
    source_account_id TEXT NOT NULL CHECK (source_account_id <> ''),
    beneficiary_account_id TEXT NOT NULL
        CHECK (beneficiary_account_id <> ''),
    amount_micro_usd BIGINT NOT NULL CHECK (amount_micro_usd > 0),
    status TEXT NOT NULL DEFAULT 'pending'
        CONSTRAINT fee_allocations_status_check CHECK (status IN (
            'pending',
            'processing',
            'projected',
            'failed',
            'cancelled'
        )),
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    worker_owner UUID,
    lease_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    projected_at TIMESTAMPTZ,
    CONSTRAINT fee_allocations_job_fk
        FOREIGN KEY (job_id)
        REFERENCES rust_coord.inference_jobs (job_id)
        ON DELETE RESTRICT,
    CONSTRAINT fee_allocations_financial_operation_fk
        FOREIGN KEY (financial_operation_id)
        REFERENCES rust_coord.financial_operations (operation_id)
        ON DELETE RESTRICT,
    CONSTRAINT fee_allocations_worker_lease_check CHECK (
        (worker_owner IS NULL) = (lease_until IS NULL)
    ),
    CONSTRAINT fee_allocations_projection_time_check CHECK (
        (status = 'projected') = (projected_at IS NOT NULL)
    ),
    CONSTRAINT fee_allocations_timestamp_order_check CHECK (
        updated_at >= created_at
        AND (projected_at IS NULL OR projected_at >= created_at)
    ),
    UNIQUE (job_id, kind),
    UNIQUE (allocation_sequence, allocation_id)
);

CREATE INDEX IF NOT EXISTS idx_rust_fee_allocations_pending
    ON rust_coord.fee_allocations (allocation_sequence)
    WHERE status IN ('pending', 'processing', 'failed');
CREATE INDEX IF NOT EXISTS idx_rust_fee_allocations_beneficiary
    ON rust_coord.fee_allocations (
        beneficiary_account_id,
        allocation_sequence DESC
    );
CREATE INDEX IF NOT EXISTS idx_rust_fee_allocations_worker_lease
    ON rust_coord.fee_allocations (lease_until)
    WHERE worker_owner IS NOT NULL;

CREATE TABLE IF NOT EXISTS rust_coord.fee_projection_checkpoints (
    projection_name TEXT PRIMARY KEY CHECK (projection_name <> ''),
    last_allocation_sequence BIGINT NOT NULL DEFAULT 0
        CHECK (last_allocation_sequence >= 0),
    last_allocation_id UUID,
    status TEXT NOT NULL DEFAULT 'idle'
        CONSTRAINT fee_projection_checkpoints_status_check CHECK (
            status IN ('idle', 'running', 'failed')
        ),
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    worker_owner UUID,
    lease_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fee_projection_checkpoints_allocation_fk
        FOREIGN KEY (last_allocation_sequence, last_allocation_id)
        REFERENCES rust_coord.fee_allocations (
            allocation_sequence,
            allocation_id
        )
        ON DELETE RESTRICT,
    CONSTRAINT fee_projection_checkpoints_position_check CHECK (
        (last_allocation_sequence = 0 AND last_allocation_id IS NULL)
        OR (last_allocation_sequence > 0 AND last_allocation_id IS NOT NULL)
    ),
    CONSTRAINT fee_projection_checkpoints_worker_lease_check CHECK (
        (worker_owner IS NULL) = (lease_until IS NULL)
    ),
    CONSTRAINT fee_projection_checkpoints_running_lease_check CHECK (
        (status = 'running') = (worker_owner IS NOT NULL)
    ),
    CONSTRAINT fee_projection_checkpoints_timestamp_order_check CHECK (
        updated_at >= created_at
    )
);

CREATE INDEX IF NOT EXISTS idx_rust_fee_projection_checkpoints_worker
    ON rust_coord.fee_projection_checkpoints (lease_until)
    WHERE worker_owner IS NOT NULL;

CREATE TABLE IF NOT EXISTS rust_coord.provider_hard_untrust_epochs (
    provider_id UUID PRIMARY KEY,
    hard_untrust_epoch BIGINT NOT NULL CHECK (hard_untrust_epoch > 0),
    reason TEXT NOT NULL CHECK (reason <> ''),
    evidence_digest BYTEA NOT NULL
        CHECK (octet_length(evidence_digest) = 32),
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT provider_hard_untrust_epochs_timestamp_order_check CHECK (
        updated_at >= created_at
    )
);

CREATE INDEX IF NOT EXISTS idx_rust_hard_untrust_updated
    ON rust_coord.provider_hard_untrust_epochs (updated_at DESC);

INSERT INTO rust_coord.schema_versions (
    version,
    minimum_public_schema_version,
    maximum_public_schema_version
)
VALUES (2, 4, 4)
ON CONFLICT (version) DO NOTHING;

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
            'rust_coord schema version 2 compatibility metadata is incompatible';
    END IF;
END $$;
