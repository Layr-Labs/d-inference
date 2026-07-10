//! Database pool and schema gate (plan §20).
//!
//! - The pool is bounded with an acquire timeout, and every connection gets a
//!   server-side `statement_timeout` at connect time (plan §14).
//! - Startup NEVER runs DDL. [`check_schema`] reads
//!   `rust_coord.schema_meta` and refuses to serve outside the supported
//!   range. Migrations are applied only by the explicit
//!   `coordinator-rs migrate` subcommand or by tests via [`run_migrations`].

use secrecy::ExposeSecret;
use sqlx::postgres::{PgConnectOptions, PgPool, PgPoolOptions};
use sqlx::ConnectOptions;

use crate::config::Config;

/// Highest `rust_coord.schema_meta.schema_version` this binary was built
/// against (migration 0008 is required: outbox drain, plan §18.1).
pub const APP_MAX_SUPPORTED_SCHEMA: i64 = 8;

/// Oldest schema version this binary can operate. All eight migrations are
/// required — the ledger touches every table they create.
pub const APP_MIN_SUPPORTED_SCHEMA: i64 = 8;

#[derive(Debug, thiserror::Error)]
pub enum DbError {
    #[error("invalid database URL: {0}")]
    InvalidUrl(String),
    #[error("database error: {0}")]
    Sqlx(#[from] sqlx::Error),
    #[error(
        "unsupported schema: schema_version={schema_version} min_reader_version={min_reader_version}, \
         app supports [{app_min}, {app_max}] — run `coordinator-rs migrate` (plan §20)"
    )]
    UnsupportedSchema {
        schema_version: i64,
        min_reader_version: i64,
        app_min: i64,
        app_max: i64,
    },
    #[error(
        "rust_coord.schema_meta is missing — migrations have never been applied; \
         run `coordinator-rs migrate` (plan §20)"
    )]
    SchemaMetaMissing,
    #[error("migration failed: {0}")]
    Migrate(#[from] sqlx::migrate::MigrateError),
}

/// Builds the bounded pool. Each connection sets its server-side
/// `statement_timeout` immediately after connecting so no statement can hold
/// the pool hostage (plan §14).
pub async fn build_pool(config: &Config) -> Result<PgPool, DbError> {
    let options: PgConnectOptions = config
        .database_url
        .expose_secret()
        .parse()
        .map_err(|e: sqlx::Error| DbError::InvalidUrl(e.to_string()))?;
    // `options` carries credentials; disable sqlx's default statement logging
    // noise for the hot path (per-query tracing happens at our call sites).
    let options = options.disable_statement_logging();

    let timeout_ms = config.db.statement_timeout.as_millis();
    let pool = PgPoolOptions::new()
        .max_connections(config.db.max_connections)
        .acquire_timeout(config.db.acquire_timeout)
        .after_connect(move |conn, _meta| {
            Box::pin(async move {
                sqlx::query(&format!("SET statement_timeout = {timeout_ms}"))
                    .execute(conn)
                    .await?;
                Ok(())
            })
        })
        .connect_with(options)
        .await?;
    Ok(pool)
}

/// Reads `rust_coord.schema_meta` and refuses startup outside the supported
/// range (plan §20):
///
/// ```text
/// APP_MIN_SUPPORTED_SCHEMA <= schema_version
/// min_reader_version       <= APP_MAX_SUPPORTED_SCHEMA
/// ```
pub async fn check_schema(pool: &PgPool) -> Result<(), DbError> {
    let row: Option<(i64, i64)> = sqlx::query_as(
        "SELECT schema_version, min_reader_version FROM rust_coord.schema_meta WHERE id = 1",
    )
    .fetch_optional(pool)
    .await
    .map_err(|err| {
        if is_undefined_object(&err) {
            DbError::SchemaMetaMissing
        } else {
            DbError::Sqlx(err)
        }
    })?;

    let (schema_version, min_reader_version) = row.ok_or(DbError::SchemaMetaMissing)?;
    if APP_MIN_SUPPORTED_SCHEMA <= schema_version && min_reader_version <= APP_MAX_SUPPORTED_SCHEMA
    {
        tracing::info!(schema_version, min_reader_version, "schema check passed");
        Ok(())
    } else {
        Err(DbError::UnsupportedSchema {
            schema_version,
            min_reader_version,
            app_min: APP_MIN_SUPPORTED_SCHEMA,
            app_max: APP_MAX_SUPPORTED_SCHEMA,
        })
    }
}

/// Applies `coordinator-rs/migrations` (sqlx format). Called ONLY by the
/// explicit `coordinator-rs migrate` subcommand and by tests — never by
/// serving startup (plan §20: application startup never runs DDL).
pub async fn run_migrations(pool: &PgPool) -> Result<(), DbError> {
    sqlx::migrate!("../../migrations").run(pool).await?;
    Ok(())
}

/// True for PostgreSQL "undefined table/schema" errors (42P01, 3F000):
/// the additive `rust_coord` schema has never been created.
fn is_undefined_object(err: &sqlx::Error) -> bool {
    matches!(
        err.as_database_error().and_then(|db| db.code()).as_deref(),
        Some("42P01") | Some("3F000")
    )
}
