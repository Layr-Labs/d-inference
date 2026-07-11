use std::time::Duration;

use sqlx::PgPool;
use thiserror::Error;
use tokio::time::timeout;

pub const MINIMUM_PUBLIC_SCHEMA_VERSION: i64 = 4;
pub const MAXIMUM_PUBLIC_SCHEMA_VERSION: i64 = 4;
pub const MINIMUM_RUST_SCHEMA_VERSION: i64 = 2;
pub const MAXIMUM_RUST_SCHEMA_VERSION: i64 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SchemaCompatibility {
    pub public_version: i64,
    pub rust_version: i64,
}

#[derive(Debug, Error)]
pub enum SchemaError {
    #[error("inspect PostgreSQL schema compatibility: {0}")]
    Inspect(#[source] sqlx::Error),
    #[error("PostgreSQL schema compatibility check exceeded {0:?}")]
    Timeout(Duration),
    #[error(
        "public schema migration history is not contiguous: minimum={minimum}, maximum={maximum}, count={count}"
    )]
    InvalidPublicHistory {
        minimum: i64,
        maximum: i64,
        count: i64,
    },
    #[error(
        "public schema version {found} is outside this Rust binary's supported range [{minimum}, {maximum}]"
    )]
    UnsupportedPublicVersion {
        found: i64,
        minimum: i64,
        maximum: i64,
    },
    #[error(
        "Rust schema migration history is not contiguous: minimum={minimum}, maximum={maximum}, count={count}"
    )]
    InvalidRustHistory {
        minimum: i64,
        maximum: i64,
        count: i64,
    },
    #[error(
        "Rust schema version {found} is outside this binary's supported range [{minimum}, {maximum}]"
    )]
    UnsupportedRustVersion {
        found: i64,
        minimum: i64,
        maximum: i64,
    },
    #[error(
        "Rust schema version {rust_version} supports public schema [{minimum}, {maximum}], not active public schema {public_version}"
    )]
    IncompatiblePublicVersion {
        rust_version: i64,
        public_version: i64,
        minimum: i64,
        maximum: i64,
    },
}

pub async fn check(
    pool: &PgPool,
    operation_timeout: Duration,
) -> Result<SchemaCompatibility, SchemaError> {
    timeout(operation_timeout, check_unbounded(pool))
        .await
        .map_err(|_| SchemaError::Timeout(operation_timeout))?
}

async fn check_unbounded(pool: &PgPool) -> Result<SchemaCompatibility, SchemaError> {
    let public = sqlx::query_as::<_, (i64, i64, i64)>(
        r#"
        SELECT
            COALESCE(MIN(version), 0),
            COALESCE(MAX(version), 0),
            COUNT(*)
        FROM public.schema_migration_versions
        "#,
    )
    .fetch_one(pool)
    .await
    .map_err(SchemaError::Inspect)?;
    validate_history(public.0, public.1, public.2, |minimum, maximum, count| {
        SchemaError::InvalidPublicHistory {
            minimum,
            maximum,
            count,
        }
    })?;
    if !(MINIMUM_PUBLIC_SCHEMA_VERSION..=MAXIMUM_PUBLIC_SCHEMA_VERSION).contains(&public.1) {
        return Err(SchemaError::UnsupportedPublicVersion {
            found: public.1,
            minimum: MINIMUM_PUBLIC_SCHEMA_VERSION,
            maximum: MAXIMUM_PUBLIC_SCHEMA_VERSION,
        });
    }

    let rust = sqlx::query_as::<_, (i64, i64, i64, i64, i64, i64)>(
        r#"
        SELECT
            versions.version,
            versions.minimum_public_schema_version,
            versions.maximum_public_schema_version,
            history.minimum,
            history.maximum,
            history.count
        FROM rust_coord.schema_versions AS versions
        CROSS JOIN (
            SELECT
                COALESCE(MIN(version), 0) AS minimum,
                COALESCE(MAX(version), 0) AS maximum,
                COUNT(*) AS count
            FROM rust_coord.schema_versions
        ) AS history
        ORDER BY versions.version DESC
        LIMIT 1
        "#,
    )
    .fetch_optional(pool)
    .await
    .map_err(SchemaError::Inspect)?
    .ok_or(SchemaError::InvalidRustHistory {
        minimum: 0,
        maximum: 0,
        count: 0,
    })?;
    validate_history(rust.3, rust.4, rust.5, |minimum, maximum, count| {
        SchemaError::InvalidRustHistory {
            minimum,
            maximum,
            count,
        }
    })?;
    if !(MINIMUM_RUST_SCHEMA_VERSION..=MAXIMUM_RUST_SCHEMA_VERSION).contains(&rust.0) {
        return Err(SchemaError::UnsupportedRustVersion {
            found: rust.0,
            minimum: MINIMUM_RUST_SCHEMA_VERSION,
            maximum: MAXIMUM_RUST_SCHEMA_VERSION,
        });
    }
    if !(rust.1..=rust.2).contains(&public.1) {
        return Err(SchemaError::IncompatiblePublicVersion {
            rust_version: rust.0,
            public_version: public.1,
            minimum: rust.1,
            maximum: rust.2,
        });
    }

    Ok(SchemaCompatibility {
        public_version: public.1,
        rust_version: rust.0,
    })
}

fn validate_history<F>(minimum: i64, maximum: i64, count: i64, error: F) -> Result<(), SchemaError>
where
    F: FnOnce(i64, i64, i64) -> SchemaError,
{
    if minimum != 1 || maximum < 1 || count != maximum {
        return Err(error(minimum, maximum, count));
    }
    Ok(())
}
