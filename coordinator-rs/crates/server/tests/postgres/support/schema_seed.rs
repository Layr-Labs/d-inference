use sqlx::{Connection, PgConnection};

use super::database::TEMP_DATABASE_PREFIX;

const DURABLE_SCHEMA_MIGRATION: &str =
    include_str!("../../../../../migrations/000002_rust_durable_schema.sql");
const PILOT_LIFECYCLE_MIGRATION: &str =
    include_str!("../../../../../migrations/000003_rust_pilot_lifecycle.sql");

pub async fn seed_durable_schema(url: &str) {
    reset_schema(url, 3, 1, 3, 3).await;
    let mut connection = PgConnection::connect(url)
        .await
        .expect("connect durable schema seed");
    sqlx::raw_sql(DURABLE_SCHEMA_MIGRATION)
        .execute(&mut connection)
        .await
        .expect("apply mirrored durable schema migration");
    sqlx::query("INSERT INTO public.schema_migration_versions (version) VALUES (4)")
        .execute(&mut connection)
        .await
        .expect("record public durable schema migration");
    sqlx::raw_sql(PILOT_LIFECYCLE_MIGRATION)
        .execute(&mut connection)
        .await
        .expect("apply mirrored pilot lifecycle migration");
    sqlx::query("INSERT INTO public.schema_migration_versions (version) VALUES (5)")
        .execute(&mut connection)
        .await
        .expect("record public pilot lifecycle migration");
    connection.close().await.expect("close durable schema seed");
}

pub async fn seed_service_schema(url: &str) {
    seed_durable_schema(url).await;
    let mut connection = PgConnection::connect(url)
        .await
        .expect("connect service schema seed");
    sqlx::raw_sql(
        r#"
        CREATE TABLE public.balances (
            account_id TEXT PRIMARY KEY,
            balance_micro_usd BIGINT NOT NULL DEFAULT 0,
            withdrawable_micro_usd BIGINT NOT NULL DEFAULT 0,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE TABLE public.ledger_entries (
            id BIGSERIAL PRIMARY KEY,
            account_id TEXT NOT NULL,
            entry_type TEXT NOT NULL,
            amount_micro_usd BIGINT NOT NULL,
            balance_after BIGINT NOT NULL,
            reference TEXT NOT NULL DEFAULT '',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE TABLE public.billing_sessions (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            payment_method TEXT NOT NULL,
            currency TEXT NOT NULL DEFAULT 'usd',
            amount_micro_usd BIGINT NOT NULL,
            external_id TEXT NOT NULL DEFAULT '',
            processed_event_id TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'pending',
            referral_code TEXT NOT NULL DEFAULT '',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            completed_at TIMESTAMPTZ
        );
        CREATE UNIQUE INDEX service_billing_external
            ON public.billing_sessions (external_id) WHERE external_id <> '';
        CREATE TABLE public.stripe_deposit_events (
            event_id TEXT PRIMARY KEY,
            checkout_session_id TEXT NOT NULL UNIQUE,
            billing_session_id TEXT NOT NULL,
            account_id TEXT NOT NULL DEFAULT '',
            amount_micro_usd BIGINT NOT NULL,
            currency TEXT NOT NULL,
            status TEXT NOT NULL,
            reason TEXT NOT NULL DEFAULT '',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE TABLE public.stripe_withdrawals (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            stripe_account_id TEXT NOT NULL,
            transfer_id TEXT NOT NULL DEFAULT '',
            payout_id TEXT NOT NULL DEFAULT '',
            sweep_payout_id TEXT NOT NULL DEFAULT '',
            amount_micro_usd BIGINT NOT NULL,
            fee_micro_usd BIGINT NOT NULL DEFAULT 0,
            net_micro_usd BIGINT NOT NULL,
            method TEXT NOT NULL,
            status TEXT NOT NULL,
            failure_reason TEXT NOT NULL DEFAULT '',
            refunded BOOLEAN NOT NULL DEFAULT FALSE,
            fee_refunded BOOLEAN NOT NULL DEFAULT FALSE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE UNIQUE INDEX service_withdrawal_transfer
            ON public.stripe_withdrawals (transfer_id) WHERE transfer_id <> '';
        CREATE UNIQUE INDEX service_withdrawal_payout
            ON public.stripe_withdrawals (payout_id) WHERE payout_id <> '';
        CREATE TABLE public.stripe_sweep_failures (
            payout_id TEXT PRIMARY KEY,
            failure_reason TEXT NOT NULL DEFAULT '',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE TABLE public.usage (
            id BIGSERIAL PRIMARY KEY,
            provider_id TEXT NOT NULL,
            consumer_key_hash TEXT NOT NULL,
            key_id TEXT NOT NULL DEFAULT '',
            model TEXT NOT NULL,
            public_model TEXT NOT NULL DEFAULT '',
            prompt_tokens INTEGER NOT NULL,
            completion_tokens INTEGER NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            request_id TEXT NOT NULL DEFAULT '',
            cost_micro_usd BIGINT NOT NULL DEFAULT 0,
            request_location JSONB
        );
        CREATE TABLE public.usage_totals (
            id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
            total_requests BIGINT NOT NULL DEFAULT 0,
            total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
            total_completion_tokens BIGINT NOT NULL DEFAULT 0
        );
        INSERT INTO public.usage_totals (id) VALUES (1);
        CREATE TABLE public.provider_earnings (
            id BIGSERIAL PRIMARY KEY,
            account_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            provider_key TEXT NOT NULL DEFAULT '',
            job_id TEXT NOT NULL,
            model TEXT NOT NULL,
            amount_micro_usd BIGINT NOT NULL,
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE TABLE public.model_registry (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            family TEXT NOT NULL DEFAULT '',
            architecture TEXT NOT NULL DEFAULT '',
            quantization TEXT NOT NULL DEFAULT '',
            max_context_length INTEGER NOT NULL DEFAULT 0,
            max_output_length INTEGER NOT NULL DEFAULT 0,
            min_ram_gb INTEGER NOT NULL DEFAULT 0,
            capabilities TEXT[] NOT NULL DEFAULT '{}',
            status TEXT NOT NULL DEFAULT 'beta',
            description TEXT NOT NULL DEFAULT '',
            runtime_parameters JSONB NOT NULL DEFAULT '{}',
            metadata JSONB NOT NULL DEFAULT '{}',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE TABLE public.model_versions (
            id BIGSERIAL PRIMARY KEY,
            model_id TEXT NOT NULL REFERENCES public.model_registry(id),
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
            UNIQUE (model_id, version)
        );
        CREATE TABLE public.model_active_versions (
            model_id TEXT PRIMARY KEY REFERENCES public.model_registry(id),
            model_version_id BIGINT NOT NULL REFERENCES public.model_versions(id),
            activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE TABLE public.model_aliases (
            alias_id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL DEFAULT '',
            builds JSONB NOT NULL DEFAULT '[]',
            desired_build TEXT NOT NULL DEFAULT '',
            previous_build TEXT NOT NULL DEFAULT '',
            retired_builds JSONB NOT NULL DEFAULT '[]',
            active BOOLEAN NOT NULL DEFAULT TRUE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE TABLE public.model_prices (
            account_id TEXT NOT NULL,
            model TEXT NOT NULL,
            input_price BIGINT NOT NULL,
            output_price BIGINT NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (account_id, model)
        );
        "#,
    )
    .execute(&mut connection)
    .await
    .expect("create service legacy tables");
    connection.close().await.expect("close service schema seed");
}

pub async fn reset_schema(
    url: &str,
    public_version: i64,
    rust_version: i64,
    minimum_public_schema_version: i64,
    maximum_public_schema_version: i64,
) {
    let mut connection = PgConnection::connect(url)
        .await
        .expect("connect isolated schema setup");
    let current_database: String = sqlx::query_scalar("SELECT current_database()")
        .fetch_one(&mut connection)
        .await
        .expect("read isolated database name");
    assert!(
        current_database.starts_with(TEMP_DATABASE_PREFIX),
        "refusing destructive schema setup outside an isolated Rust test database: {current_database}"
    );
    sqlx::raw_sql(
        r#"
        DROP SCHEMA IF EXISTS rust_coord CASCADE;
        DROP TABLE IF EXISTS public.coordinator_ownership CASCADE;
        DROP TABLE IF EXISTS public.schema_migrations CASCADE;
        DROP TABLE IF EXISTS public.schema_migration_versions CASCADE;

        CREATE TABLE public.schema_migration_versions (
            version BIGINT PRIMARY KEY
        );
        CREATE TABLE public.schema_migrations (
            id TEXT PRIMARY KEY,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE TABLE public.coordinator_ownership (
            singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
            epoch BIGINT NOT NULL,
            owner_id TEXT NOT NULL,
            acquired_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE SCHEMA rust_coord;
        CREATE TABLE rust_coord.schema_versions (
            version BIGINT PRIMARY KEY,
            minimum_public_schema_version BIGINT NOT NULL,
            maximum_public_schema_version BIGINT NOT NULL,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        "#,
    )
    .execute(&mut connection)
    .await
    .expect("reset isolated PostgreSQL schemas");
    sqlx::query(
        "INSERT INTO public.schema_migration_versions (version) SELECT generate_series(1, $1)",
    )
    .bind(public_version)
    .execute(&mut connection)
    .await
    .expect("seed isolated public schema versions");
    sqlx::query(
        r#"
        INSERT INTO rust_coord.schema_versions (
            version,
            minimum_public_schema_version,
            maximum_public_schema_version
        )
        SELECT
            version,
            CASE WHEN version = $1 THEN $2 ELSE 1 END,
            $3
        FROM generate_series(1, $1) AS version
        "#,
    )
    .bind(rust_version)
    .bind(minimum_public_schema_version)
    .bind(maximum_public_schema_version)
    .execute(&mut connection)
    .await
    .expect("seed isolated Rust schema versions");
    connection
        .close()
        .await
        .expect("close isolated schema setup");
}
