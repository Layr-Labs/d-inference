use sqlx::{Connection, PgConnection};

use super::database::TEMP_DATABASE_PREFIX;

const LEGACY_PUBLIC_SCHEMA: &str =
    include_str!("../../../../../../coordinator/store/migrations/000001_legacy_schema.sql");
const DURABLE_SCHEMA_MIGRATION: &str =
    include_str!("../../../../../migrations/000002_rust_durable_schema.sql");
const PILOT_LIFECYCLE_MIGRATION: &str =
    include_str!("../../../../../migrations/000003_rust_pilot_lifecycle.sql");
const OBJECTIVE7_CONTROLS_MIGRATION: &str =
    include_str!("../../../../../migrations/000004_objective7_controls.sql");

pub async fn seed_durable_schema(url: &str) {
    reset_schema(url, 3, 1, 3, 3).await;
    let mut connection = PgConnection::connect(url)
        .await
        .expect("connect durable schema seed");
    sqlx::raw_sql(LEGACY_PUBLIC_SCHEMA)
        .execute(&mut connection)
        .await
        .expect("apply legacy public schema migration");
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
    sqlx::query(
        r#"
        INSERT INTO public.provider_tokens (
            token_hash, account_id, label, active
        ) VALUES (
            'pre-objective7-disabled-token',
            'migration-fixture-account',
            'migration fixture',
            FALSE
        )
        "#,
    )
    .execute(&mut connection)
    .await
    .expect("seed legacy disabled provider token");
    sqlx::raw_sql(OBJECTIVE7_CONTROLS_MIGRATION)
        .execute(&mut connection)
        .await
        .expect("apply Objective 7 controls migration");
    let migrated_revocation: bool = sqlx::query_scalar(
        "SELECT revoked_at IS NOT NULL FROM public.provider_tokens WHERE token_hash='pre-objective7-disabled-token'",
    )
    .fetch_one(&mut connection)
    .await
    .expect("load migrated disabled provider token");
    assert!(
        migrated_revocation,
        "Objective 7 migration must backfill disabled-token revocation"
    );
    sqlx::query(
        "DELETE FROM public.provider_tokens WHERE token_hash='pre-objective7-disabled-token'",
    )
    .execute(&mut connection)
    .await
    .expect("remove migration fixture provider token");
    sqlx::query("INSERT INTO public.schema_migration_versions (version) VALUES (6)")
        .execute(&mut connection)
        .await
        .expect("record public Objective 7 migration");
    connection.close().await.expect("close durable schema seed");
}

pub async fn seed_service_schema(url: &str) {
    seed_durable_schema(url).await;
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
