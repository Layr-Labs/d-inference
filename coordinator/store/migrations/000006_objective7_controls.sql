-- Production control-plane durability for the integrated Rust HTTP surface.
--
-- coordinator-rs/migrations/000004_objective7_controls.sql is a byte-for-byte
-- mirror. Serving startup never executes this DDL.

DO $$
BEGIN
    IF (
        SELECT COUNT(*)
        FROM public.schema_migration_versions
    ) <> 5 OR NOT EXISTS (
        SELECT 1
        FROM public.schema_migration_versions
        WHERE version = 5
    ) THEN
        RAISE EXCEPTION
            'public schema must be at version 5 before Objective 7 controls migration';
    END IF;
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
            'rust_coord schema must be at version 3 before Objective 7 controls migration';
    END IF;
END $$;

ALTER TABLE public.provider_tokens
    ADD COLUMN provider_id TEXT NOT NULL DEFAULT '',
    ADD COLUMN x25519_public_key TEXT NOT NULL DEFAULT '',
    ADD COLUMN se_public_key TEXT NOT NULL DEFAULT '',
    ADD COLUMN revoked_at TIMESTAMPTZ,
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Existing disabled tokens predate revoked_at. Preserve their disabled state
-- while satisfying the new active/revocation equivalence.
UPDATE public.provider_tokens
SET revoked_at = COALESCE(revoked_at, updated_at)
WHERE NOT active;

ALTER TABLE public.provider_tokens
    ADD CONSTRAINT provider_tokens_active_revocation_check CHECK (
        active <> (revoked_at IS NOT NULL)
    ),
    ADD CONSTRAINT provider_tokens_bound_keys_check CHECK (
        (x25519_public_key = '') = (se_public_key = '')
    );

CREATE UNIQUE INDEX idx_provider_tokens_provider_identity
    ON public.provider_tokens (provider_id)
    WHERE provider_id <> '';

ALTER TABLE public.providers
    ADD COLUMN token_hash TEXT NOT NULL DEFAULT '',
    ADD COLUMN connected BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN session_id TEXT NOT NULL DEFAULT '',
    ADD COLUMN provider_process_generation TEXT NOT NULL DEFAULT '',
    ADD COLUMN session_epoch BIGINT NOT NULL DEFAULT 0
        CHECK (session_epoch >= 0),
    ADD COLUMN hard_untrust_epoch BIGINT NOT NULL DEFAULT 0
        CHECK (hard_untrust_epoch >= 0),
    ADD COLUMN mdm_udid TEXT NOT NULL DEFAULT '',
    ADD COLUMN mdm_enrolled BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN mdm_sip_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN mdm_secure_boot_full BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN mdm_security_info_at TIMESTAMPTZ,
    ADD CONSTRAINT providers_connected_session_check CHECK (
        NOT connected OR (session_id <> '' AND session_epoch > 0)
    );

CREATE INDEX idx_providers_token_hash
    ON public.providers (token_hash)
    WHERE token_hash <> '';

ALTER TABLE public.provider_trust_reuse
    ADD COLUMN provider_id TEXT NOT NULL DEFAULT '',
    ADD COLUMN hard_untrust_epoch BIGINT NOT NULL DEFAULT 0
        CHECK (hard_untrust_epoch >= 0),
    ADD COLUMN enrolled BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN security_info_at TIMESTAMPTZ;

-- Legacy reuse rows do not contain the provider/session identity or current
-- enrollment fact required by the Rust hardware-trust proof. They are a cache,
-- not an accounting record, so discard them instead of manufacturing evidence.
DELETE FROM public.provider_trust_reuse;

ALTER TABLE public.provider_trust_reuse
    ADD CONSTRAINT provider_trust_reuse_hardware_check CHECK (
        trust_level <> 'hardware'
        OR (
            provider_id <> ''
            AND serial <> ''
            AND binary_hash <> ''
            AND mda_udid <> ''
            AND sip_enabled
            AND secure_boot_full
            AND enrolled
            AND security_info_at IS NOT NULL
        )
    );

CREATE UNIQUE INDEX idx_provider_trust_reuse_provider
    ON public.provider_trust_reuse (provider_id)
    WHERE provider_id <> '';

CREATE TABLE rust_coord.mdm_command_expectations (
    command_uuid TEXT PRIMARY KEY
        CHECK (
            command_uuid <> ''
            AND command_uuid = btrim(command_uuid)
            AND octet_length(command_uuid) <= 128
        ),
    command TEXT NOT NULL
        CHECK (command IN ('SecurityInfo', 'DeviceInformation')),
    provider_id UUID NOT NULL,
    session_epoch BIGINT NOT NULL CHECK (session_epoch > 0),
    serial TEXT NOT NULL CHECK (serial <> ''),
    udid TEXT NOT NULL CHECK (udid <> ''),
    se_public_key TEXT NOT NULL CHECK (se_public_key <> ''),
    binary_hash TEXT NOT NULL CHECK (binary_hash <> ''),
    expected_sip BOOLEAN NOT NULL,
    expected_secure_boot BOOLEAN NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'applied', 'rejected', 'expired')),
    evidence JSONB,
    failure_reason TEXT NOT NULL DEFAULT '',
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    CONSTRAINT mdm_command_expiry_check CHECK (expires_at > issued_at),
    CONSTRAINT mdm_command_completion_check CHECK (
        (status = 'pending' AND completed_at IS NULL)
        OR (status <> 'pending' AND completed_at IS NOT NULL)
    )
);

CREATE INDEX idx_rust_mdm_commands_pending
    ON rust_coord.mdm_command_expectations (expires_at, issued_at)
    WHERE status = 'pending';

CREATE TABLE rust_coord.api_key_rate_windows (
    credential_hash TEXT NOT NULL CHECK (credential_hash <> ''),
    window_started_at TIMESTAMPTZ NOT NULL,
    request_count BIGINT NOT NULL DEFAULT 0 CHECK (request_count >= 0),
    input_tokens BIGINT NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
    reserved_output_tokens BIGINT NOT NULL DEFAULT 0
        CHECK (reserved_output_tokens >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (credential_hash, window_started_at)
);

CREATE INDEX idx_rust_api_key_rate_windows_updated
    ON rust_coord.api_key_rate_windows (updated_at);

ALTER TABLE public.model_prices
    ADD COLUMN revision BIGINT NOT NULL DEFAULT 1
        CHECK (revision > 0);

CREATE FUNCTION public.bump_model_price_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.revision := OLD.revision + 1;
    RETURN NEW;
END;
$$;

CREATE TRIGGER model_prices_revision
BEFORE UPDATE OF input_price, output_price ON public.model_prices
FOR EACH ROW
EXECUTE FUNCTION public.bump_model_price_revision();

ALTER TABLE rust_coord.inference_jobs
    ADD COLUMN api_key_reserved_micro_usd BIGINT NOT NULL DEFAULT 0
        CHECK (api_key_reserved_micro_usd >= 0);

CREATE TABLE rust_coord.telemetry_events (
    telemetry_event_id UUID PRIMARY KEY,
    event_name TEXT NOT NULL
        CHECK (
            event_name <> ''
            AND event_name = btrim(event_name)
            AND octet_length(event_name) <= 128
        ),
    identity_hash TEXT NOT NULL CHECK (identity_hash <> ''),
    authenticated BOOLEAN NOT NULL,
    fields JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(fields) = 'object'),
    payload_bytes INTEGER NOT NULL CHECK (payload_bytes > 0),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'delivered', 'dropped')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    worker_owner UUID,
    lease_until TIMESTAMPTZ,
    last_error TEXT NOT NULL DEFAULT '',
    owner_epoch BIGINT NOT NULL CHECK (owner_epoch > 0),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivered_at TIMESTAMPTZ,
    CONSTRAINT telemetry_event_lease_check CHECK (
        (status = 'processing' AND worker_owner IS NOT NULL AND lease_until IS NOT NULL)
        OR (status <> 'processing' AND worker_owner IS NULL AND lease_until IS NULL)
    )
);

CREATE INDEX idx_rust_telemetry_pending
    ON rust_coord.telemetry_events (next_attempt_at, created_at)
    WHERE status IN ('pending', 'processing');

ALTER TABLE public.stripe_withdrawals
    ADD COLUMN idempotency_key TEXT NOT NULL DEFAULT '',
    ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0
        CHECK (attempt_count >= 0),
    ADD COLUMN max_attempts INTEGER NOT NULL DEFAULT 10
        CHECK (max_attempts > 0),
    ADD COLUMN next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN external_state TEXT NOT NULL DEFAULT 'not_started'
        CHECK (external_state IN (
            'not_started',
            'submitted_unknown',
            'confirmed',
            'external_unknown',
            'permanent_failure'
        )),
    ADD COLUMN provenance JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(provenance) = 'object'),
    ADD COLUMN completed_at TIMESTAMPTZ,
    ADD CONSTRAINT stripe_withdrawal_attempt_bound_check CHECK (
        attempt_count <= max_attempts
    );

UPDATE public.stripe_withdrawals
SET idempotency_key = 'legacy-withdrawal:' || id
WHERE idempotency_key = '';

ALTER TABLE public.stripe_withdrawals
    ADD CONSTRAINT stripe_withdrawal_idempotency_required CHECK (
        idempotency_key <> ''
    );

CREATE UNIQUE INDEX idx_stripe_withdrawals_idempotency
    ON public.stripe_withdrawals (idempotency_key);

CREATE INDEX idx_stripe_withdrawals_recovery
    ON public.stripe_withdrawals (next_attempt_at, created_at)
    WHERE status IN ('pending', 'processing');

CREATE INDEX idx_device_codes_expiry
    ON public.device_codes (expires_at);

CREATE TABLE public.stripe_withdrawal_failures (
    withdrawal_id TEXT PRIMARY KEY
        REFERENCES public.stripe_withdrawals (id) ON DELETE RESTRICT,
    idempotency_key TEXT NOT NULL UNIQUE,
    account_id TEXT NOT NULL,
    amount_micro_usd BIGINT NOT NULL CHECK (amount_micro_usd > 0),
    fee_micro_usd BIGINT NOT NULL CHECK (fee_micro_usd >= 0),
    reason TEXT NOT NULL CHECK (reason <> ''),
    attempts INTEGER NOT NULL CHECK (attempts > 0),
    refunded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE public.billing_runtime_settings (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    platform_account_id TEXT NOT NULL DEFAULT 'platform'
        CHECK (platform_account_id <> ''),
    base_reservation_micro_usd BIGINT NOT NULL DEFAULT 1
        CHECK (base_reservation_micro_usd > 0),
    provider_share_ppm INTEGER NOT NULL DEFAULT 1000000
        CHECK (provider_share_ppm BETWEEN 0 AND 1000000),
    referral_share_ppm INTEGER NOT NULL DEFAULT 200000
        CHECK (referral_share_ppm BETWEEN 0 AND 1000000),
    rounding_version BIGINT NOT NULL DEFAULT 1 CHECK (rounding_version > 0),
    revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.billing_runtime_settings (singleton)
VALUES (TRUE);

INSERT INTO rust_coord.schema_versions (
    version,
    minimum_public_schema_version,
    maximum_public_schema_version
)
VALUES (4, 6, 6);

DO $$
BEGIN
    IF (
        SELECT COUNT(*)
        FROM rust_coord.schema_versions
    ) <> 4 OR NOT EXISTS (
        SELECT 1
        FROM rust_coord.schema_versions
        WHERE version = 4
          AND minimum_public_schema_version = 6
          AND maximum_public_schema_version = 6
    ) THEN
        RAISE EXCEPTION
            'rust_coord schema version 4 compatibility metadata is incompatible';
    END IF;
END $$;
