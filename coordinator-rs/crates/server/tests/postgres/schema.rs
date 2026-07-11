use std::time::Duration;

use darkbloom_coordinator_server::{
    database::{Database, DatabaseError},
    ownership::OwnershipError,
    schema::SchemaError,
};
use sqlx::PgPool;

use super::support::{reset_schema, seed_durable_schema, with_isolated_database};

#[tokio::test]
async fn database_enforces_public_and_rust_schema_ranges() {
    with_isolated_database(|url| async move {
        reset_schema(&url, 4, 2, 4, 4).await;
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

        for public_version in [3, 5] {
            reset_schema(&url, public_version, 2, 4, 4).await;
            let error = Database::connect(&url, 2, Duration::from_secs(3))
                .await
                .expect_err("unsupported public schema was accepted");
            assert!(matches!(
                error,
                DatabaseError::Schema(SchemaError::UnsupportedPublicVersion {
                    found,
                    minimum: 4,
                    maximum: 4,
                }) if found == public_version
            ));
        }

        reset_schema(&url, 4, 3, 4, 4).await;
        let error = Database::connect(&url, 2, Duration::from_secs(3))
            .await
            .expect_err("unsupported Rust schema was accepted");
        assert!(matches!(
            error,
            DatabaseError::Schema(SchemaError::UnsupportedRustVersion {
                found: 3,
                minimum: 2,
                maximum: 2,
            })
        ));

        reset_schema(&url, 4, 2, 5, 5).await;
        let error = Database::connect(&url, 2, Duration::from_secs(3))
            .await
            .expect_err("incompatible public/Rust schema pair was accepted");
        assert!(matches!(
            error,
            DatabaseError::Schema(SchemaError::IncompatiblePublicVersion {
                rust_version: 2,
                public_version: 4,
                minimum: 5,
                maximum: 5,
            })
        ));
    })
    .await;
}

#[tokio::test]
async fn mirrored_migration_builds_the_sqlx_schema_contract() {
    with_isolated_database(|url| async move {
        seed_durable_schema(&url).await;
        let database = Database::connect(&url, 2, Duration::from_secs(3))
            .await
            .expect("connect against durable schema");
        assert_eq!(database.compatibility().public_version, 4);
        assert_eq!(database.compatibility().rust_version, 2);

        let inspector = PgPool::connect(&url)
            .await
            .expect("connect durable schema inspector");
        let tables: Vec<String> = sqlx::query_scalar(
            r#"
            SELECT relation.relname
            FROM pg_class AS relation
            JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = 'rust_coord'
              AND relation.relkind IN ('r', 'p')
            ORDER BY relation.relname
            "#,
        )
        .fetch_all(&inspector)
        .await
        .expect("list Rust schema tables");
        assert_eq!(
            tables,
            [
                "external_events",
                "fee_allocations",
                "fee_projection_checkpoints",
                "financial_operations",
                "inference_attempts",
                "inference_jobs",
                "outbox",
                "provider_hard_untrust_epochs",
                "provider_terminals",
                "schema_versions",
            ]
        );

        let foreign_keys: Vec<String> = sqlx::query_scalar(
            r#"
            SELECT constraint_row.conname
            FROM pg_constraint AS constraint_row
            JOIN pg_class AS relation ON relation.oid = constraint_row.conrelid
            JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = 'rust_coord'
              AND constraint_row.contype = 'f'
            ORDER BY constraint_row.conname
            "#,
        )
        .fetch_all(&inspector)
        .await
        .expect("list Rust schema foreign keys");
        assert_eq!(
            foreign_keys,
            [
                "external_events_financial_operation_fk",
                "fee_allocations_financial_operation_fk",
                "fee_allocations_job_fk",
                "fee_projection_checkpoints_allocation_fk",
                "financial_operations_job_fk",
                "financial_operations_terminal_fk",
                "inference_attempts_job_fk",
                "outbox_financial_operation_fk",
                "outbox_job_fk",
                "provider_terminals_attempt_fk",
            ]
        );

        let status_error = sqlx::query(
            r#"
            INSERT INTO rust_coord.external_events (
                external_event_id, source, event_id, event_kind,
                payload_digest, status, owner_epoch
            ) VALUES (
                '20000000-0000-0000-0000-000000000001',
                'stripe', 'evt_invalid', 'checkout',
                decode(repeat('20', 32), 'hex'), 'future_status', 1
            )
            "#,
        )
        .execute(&inspector)
        .await
        .expect_err("unknown external status passed its CHECK");
        assert_eq!(
            status_error
                .as_database_error()
                .and_then(|error| error.code())
                .as_deref(),
            Some("23514")
        );

        let foreign_key_error = sqlx::query(
            r#"
            INSERT INTO rust_coord.inference_attempts (
                attempt_id, job_id, provider_id,
                provider_process_generation_id, session_epoch, owner_epoch,
                permit_id, dispatch_nonce, request_digest, kind
            ) VALUES (
                '20000000-0000-0000-0000-000000000002',
                '20000000-0000-0000-0000-000000000003',
                '20000000-0000-0000-0000-000000000004',
                '20000000-0000-0000-0000-000000000005',
                1, 1,
                '20000000-0000-0000-0000-000000000006',
                decode(repeat('21', 32), 'hex'),
                decode(repeat('22', 32), 'hex'),
                'primary'
            )
            "#,
        )
        .execute(&inspector)
        .await
        .expect_err("attempt with unknown job passed its foreign key");
        assert_eq!(
            foreign_key_error
                .as_database_error()
                .and_then(|error| error.code())
                .as_deref(),
            Some("23503")
        );

        inspector.close().await;
        database
            .close(Duration::from_secs(2))
            .await
            .expect("close durable schema pool");
    })
    .await;
}
