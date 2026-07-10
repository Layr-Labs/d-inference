use sqlx::{Connection, PgConnection};

use super::database::TEMP_DATABASE_PREFIX;

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
