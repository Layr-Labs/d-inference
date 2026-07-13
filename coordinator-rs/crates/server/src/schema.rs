use std::time::Duration;

use sqlx::PgPool;
use thiserror::Error;
use tokio::time::timeout;

pub const MINIMUM_PUBLIC_SCHEMA_VERSION: i64 = 7;
pub const MAXIMUM_PUBLIC_SCHEMA_VERSION: i64 = 7;
pub const MINIMUM_RUST_SCHEMA_VERSION: i64 = 4;
pub const MAXIMUM_RUST_SCHEMA_VERSION: i64 = 5;

const PUBLIC_MIGRATION_CHECKSUMS: [&str; 7] = [
    "f565ec9ebf5327ece27cb2220867e157a805e93ae5ba4e782fed47ae183583d6",
    "19094e442b43df4ac4e45cc79a3a12c1c627ce75c3a189a48963afd72d6a5503",
    "38f7d7db044465256bc841eb545546e35c115ea0af74401637d928672046f216",
    "9a76eb79c49a4ba8bf576eb07cd8e6c9386641b9e4978cbaffa781321296b3d5",
    "c4a118c607d2d0951d644ecc9db3621d31dcf7a4aecdb9485f7b8ecf4533b129",
    "f2e426e4d4bd1d34c908ab724b43d89c2bcabf422323902de321fda83ce4a5a5",
    "eee91c778786161b6dac8c070c82a130c4c96c98f2a0bb96f28876b864cdb62d",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SchemaCompatibility {
    pub public_version: i64,
    pub rust_version: i64,
    pub migration_checksum_valid: bool,
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
    #[error("public schema migration checksum mismatch at version {version}")]
    PublicChecksumMismatch { version: i64 },
    #[cfg(feature = "fault-injection")]
    #[error("injected schema fault at {0}")]
    InjectedFault(&'static str),
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
    validate_public_checksums(pool).await?;

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
        migration_checksum_valid: true,
    })
}

async fn validate_public_checksums(pool: &PgPool) -> Result<(), SchemaError> {
    let rows = sqlx::query_as::<_, (i64, String)>(
        r#"
        SELECT version, checksum
        FROM public.schema_migration_versions
        ORDER BY version
        "#,
    )
    .fetch_all(pool)
    .await
    .map_err(SchemaError::Inspect)?;
    crate::fault_checkpoint_async!(MigrationChecksum, "validate_public_checksums", |error| {
        SchemaError::InjectedFault(error.point().as_str())
    });
    for (index, expected) in PUBLIC_MIGRATION_CHECKSUMS.iter().enumerate() {
        let version = i64::try_from(index + 1).expect("migration catalog length fits i64");
        let valid = rows.get(index).is_some_and(|(found_version, checksum)| {
            *found_version == version && checksum == expected
        });
        if !valid {
            return Err(SchemaError::PublicChecksumMismatch { version });
        }
    }
    Ok(())
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

#[cfg(test)]
mod tests {
    use std::fmt::Write as _;

    use sha2::{Digest as _, Sha256};

    use super::PUBLIC_MIGRATION_CHECKSUMS;

    const PUBLIC_MIGRATIONS: [&[u8]; 6] = [
        include_bytes!("../../../../coordinator/store/migrations/000001_legacy_schema.sql"),
        include_bytes!(
            "../../../../coordinator/store/migrations/000002_provider_earnings_job_index.sql"
        ),
        include_bytes!(
            "../../../../coordinator/store/migrations/000003_rust_schema_compatibility.sql"
        ),
        include_bytes!("../../../../coordinator/store/migrations/000004_rust_durable_schema.sql"),
        include_bytes!("../../../../coordinator/store/migrations/000005_rust_pilot_lifecycle.sql"),
        include_bytes!("../../../../coordinator/store/migrations/000006_objective7_controls.sql"),
    ];

    #[test]
    fn compiled_public_migration_checksums_match_authoritative_catalog() {
        for (migration, expected) in PUBLIC_MIGRATIONS.iter().zip(PUBLIC_MIGRATION_CHECKSUMS) {
            let actual = Sha256::digest(migration).iter().fold(
                String::with_capacity(64),
                |mut output, byte| {
                    write!(output, "{byte:02x}").expect("write digest");
                    output
                },
            );
            assert_eq!(actual, expected);
        }
    }
}
