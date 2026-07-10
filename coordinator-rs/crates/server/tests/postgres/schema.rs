use std::time::Duration;

use darkbloom_coordinator_server::{
    database::{Database, DatabaseError},
    ownership::OwnershipError,
    schema::SchemaError,
};
use sqlx::PgPool;

use super::support::{reset_schema, with_isolated_database};

#[tokio::test]
async fn database_enforces_public_and_rust_schema_ranges() {
    with_isolated_database(|url| async move {
        reset_schema(&url, 3, 1, 3, 3).await;
        let supported = Database::connect(&url, 2, Duration::from_secs(3))
            .await
            .expect("supported schema range");
        let unfenced = supported
            .begin_owned()
            .await
            .expect_err("unconfigured pool created an owned transaction");
        assert!(matches!(
            unfenced,
            DatabaseError::Ownership(OwnershipError::NotConfigured)
        ));
        let inspector = PgPool::connect(&url)
            .await
            .expect("connect schema inspector");
        let activation_rows: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM public.schema_migrations WHERE id = 'coordinator_ownership_activated'",
        )
        .fetch_one(&inspector)
        .await
        .expect("count activation rows");
        let ownership_rows: i64 =
            sqlx::query_scalar("SELECT count(*) FROM public.coordinator_ownership")
                .fetch_one(&inspector)
                .await
                .expect("count ownership rows");
        assert_eq!(activation_rows, 0);
        assert_eq!(ownership_rows, 0);
        inspector.close().await;
        supported
            .close(Duration::from_secs(2))
            .await
            .expect("close supported schema pool");

        for public_version in [2, 4] {
            reset_schema(&url, public_version, 1, 3, 3).await;
            let error = Database::connect(&url, 2, Duration::from_secs(3))
                .await
                .expect_err("unsupported public schema was accepted");
            assert!(matches!(
                error,
                DatabaseError::Schema(SchemaError::UnsupportedPublicVersion {
                    found,
                    minimum: 3,
                    maximum: 3,
                }) if found == public_version
            ));
        }

        reset_schema(&url, 3, 2, 3, 3).await;
        let error = Database::connect(&url, 2, Duration::from_secs(3))
            .await
            .expect_err("unsupported Rust schema was accepted");
        assert!(matches!(
            error,
            DatabaseError::Schema(SchemaError::UnsupportedRustVersion {
                found: 2,
                minimum: 1,
                maximum: 1,
            })
        ));

        reset_schema(&url, 3, 1, 4, 4).await;
        let error = Database::connect(&url, 2, Duration::from_secs(3))
            .await
            .expect_err("incompatible public/Rust schema pair was accepted");
        assert!(matches!(
            error,
            DatabaseError::Schema(SchemaError::IncompatiblePublicVersion {
                rust_version: 1,
                public_version: 3,
                minimum: 4,
                maximum: 4,
            })
        ));
    })
    .await;
}
