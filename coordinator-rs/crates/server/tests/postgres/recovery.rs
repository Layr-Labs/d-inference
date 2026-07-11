use std::time::Duration;

use darkbloom_coordinator_core::ids::Digest;
use darkbloom_coordinator_server::{
    database::Database,
    db::catalog::CatalogService,
    ledger::{
        AccountId, JobId, LedgerAmount, LedgerService, Operation, OperationKey, ReservationId,
        ReserveRequest,
    },
    ownership::CoordinatorOwnership,
    projection::FeeProjectionService,
    recovery::{JobRecoveryAction, RecoveryService},
};
use sqlx::PgPool;
use tokio::time::sleep;
use uuid::Uuid;

use super::support::{seed_service_schema, with_isolated_database};

#[tokio::test]
async fn skip_locked_workers_claim_distinct_jobs_and_expired_lease_is_taken_over() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('consumer', 10000, 10000)",
        )
        .execute(&pool)
        .await
        .expect("balance");
        let ledger = LedgerService::new(database.clone());
        for index in 0..3 {
            ledger
                .reserve(&reserve_request(index))
                .await
                .expect("reserve recovery job");
        }

        let recovery = RecoveryService::new(database.clone());
        let first_worker = Uuid::new_v4();
        let second_worker = Uuid::new_v4();
        let first_service = recovery.clone();
        let second_service = recovery.clone();
        let first = tokio::spawn(async move {
            first_service
                .claim_jobs(first_worker, 1, Duration::from_millis(100))
                .await
                .expect("first claim")
        });
        let second = tokio::spawn(async move {
            second_service
                .claim_jobs(second_worker, 1, Duration::from_millis(100))
                .await
                .expect("second claim")
        });
        let (first, second) = tokio::join!(first, second);
        let first = first.expect("first task");
        let second = second.expect("second task");
        assert_eq!(first.len(), 1);
        assert_eq!(second.len(), 1);
        assert_ne!(first[0].job_id, second[0].job_id);
        assert_eq!(
            first[0].action,
            JobRecoveryAction::ReleasePreAuthorization
        );

        let remaining = recovery
            .claim_jobs(Uuid::new_v4(), 1, Duration::from_millis(1))
            .await
            .expect("remaining claim");
        assert_eq!(remaining.len(), 1);
        sleep(Duration::from_millis(5)).await;
        let takeover = recovery
            .claim_jobs(Uuid::new_v4(), 3, Duration::from_millis(50))
            .await
            .expect("lease takeover");
        assert!(
            takeover
                .iter()
                .any(|lease| lease.job_id == remaining[0].job_id)
        );

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn recovery_classifies_pre_and_post_authorization_without_redispatch() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('consumer', 10000, 10000)",
        )
        .execute(&pool)
        .await
        .expect("balance");
        let ledger = LedgerService::new(database.clone());
        let reserved_job = ledger
            .reserve(&reserve_request(60))
            .await
            .expect("reserved job")
            .job_id;
        let prepared_job = ledger
            .reserve(&reserve_request(61))
            .await
            .expect("prepared job")
            .job_id;
        let authorized_job = ledger
            .reserve(&reserve_request(62))
            .await
            .expect("authorized job")
            .job_id;
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let attempt_id = Uuid::new_v4();
        let request_digest = digest(63);
        sqlx::query(
            "UPDATE rust_coord.inference_jobs SET state = 'prepared' WHERE job_id = $1",
        )
        .bind(prepared_job.as_uuid())
        .execute(&pool)
        .await
        .expect("prepared state");
        sqlx::query(
            r#"
            UPDATE rust_coord.inference_jobs
            SET state = 'start_authorized',
                concrete_model = 'model/build',
                public_model = 'model',
                pricing_version = 1,
                rounding_version = 1,
                billable_input_tokens = 1,
                bounded_output_tokens = 1,
                provider_id = $2,
                provider_account_id = 'provider',
                provider_payout_micro_usd = 50,
                platform_fee_micro_usd = 50,
                request_digest = $3
            WHERE job_id = $1
            "#,
        )
        .bind(authorized_job.as_uuid())
        .bind(provider_id)
        .bind(request_digest.as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("authorized state");
        sqlx::query(
            r#"
            INSERT INTO rust_coord.inference_attempts (
                attempt_id, job_id, provider_id,
                provider_process_generation_id, session_epoch, owner_epoch,
                lease_id, permit_id, dispatch_nonce, request_digest, kind, state
            ) VALUES ($1, $2, $3, $4, 1, 1, $5, $6, $7, $8, 'primary', 'started')
            "#,
        )
        .bind(attempt_id)
        .bind(authorized_job.as_uuid())
        .bind(provider_id)
        .bind(generation_id)
        .bind(Uuid::new_v4())
        .bind(Uuid::new_v4())
        .bind(digest(64).as_bytes().as_slice())
        .bind(request_digest.as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("authorized attempt");
        let terminal_id = Uuid::new_v4();
        sqlx::query(
            r#"
            INSERT INTO rust_coord.provider_terminals (
                terminal_id, job_id, attempt_id, provider_id,
                provider_process_generation_id, origin_session_epoch,
                terminal_digest, raw_terminal, outcome, prompt_tokens,
                completion_tokens, response_digest, rolling_digest,
                final_generated_tokens, provider_signature, owner_epoch
            ) VALUES (
                $1, $2, $3, $4, $5, 1, $6, '{}', 'completed', 1, 1,
                $7, $8, 1, '\x01', 1
            )
            "#,
        )
        .bind(terminal_id)
        .bind(authorized_job.as_uuid())
        .bind(attempt_id)
        .bind(provider_id)
        .bind(generation_id)
        .bind(digest(65).as_bytes().as_slice())
        .bind(digest(66).as_bytes().as_slice())
        .bind(digest(67).as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("pending terminal");

        let recovery = RecoveryService::new(database.clone());
        let leases = recovery
            .claim_jobs(Uuid::new_v4(), 10, Duration::from_secs(1))
            .await
            .expect("state claims");
        let action = |job_id| {
            leases
                .iter()
                .find(|lease| lease.job_id == job_id)
                .expect("claimed job")
                .action
        };
        assert_eq!(
            action(reserved_job),
            JobRecoveryAction::ReleasePreAuthorization
        );
        assert_eq!(
            action(prepared_job),
            JobRecoveryAction::ReleasePreAuthorization
        );
        assert_eq!(
            action(authorized_job),
            JobRecoveryAction::AwaitAuthorizedTerminal
        );
        let terminals = recovery
            .claim_terminals(Uuid::new_v4(), 10, Duration::from_secs(1))
            .await
            .expect("terminal claim");
        assert_eq!(terminals.len(), 1);
        assert_eq!(terminals[0].terminal_id.as_uuid(), terminal_id);

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn external_outbox_and_fee_projection_leases_are_version_fenced() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('consumer', 1000, 1000)",
        )
        .execute(&pool)
        .await
        .expect("balance");
        let reserve = reserve_request(9);
        LedgerService::new(database.clone())
            .reserve(&reserve)
            .await
            .expect("reserve");
        let operation_id: Uuid = sqlx::query_scalar(
            "SELECT operation_id FROM rust_coord.financial_operations WHERE operation_key = $1",
        )
        .bind(reserve.operation.key.as_str())
        .fetch_one(&pool)
        .await
        .expect("operation id");
        let external_id = Uuid::new_v4();
        let outbox_id = Uuid::new_v4();
        sqlx::query(
            r#"
            INSERT INTO rust_coord.external_events (
                external_event_id, source, event_id, event_kind,
                payload_digest, payload, status, owner_epoch
            ) VALUES ($1, 'stripe', 'evt-unknown', 'unknown', $2, '{}', 'pending', 99)
            "#,
        )
        .bind(external_id)
        .bind(digest(44).as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("external recovery row");
        sqlx::query(
            r#"
            INSERT INTO rust_coord.outbox (
                outbox_id, operation_key, payload_digest, kind, status,
                payload, owner_epoch
            ) VALUES ($1, 'outbox:test', $2, 'external_call', 'pending', '{}', 99)
            "#,
        )
        .bind(outbox_id)
        .bind(digest(44).as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("outbox recovery row");
        sqlx::query(
            r#"
            INSERT INTO rust_coord.fee_allocations (
                allocation_id, operation_key, job_id, financial_operation_id,
                kind, source_account_id, beneficiary_account_id,
                amount_micro_usd, owner_epoch
            ) VALUES (
                gen_random_uuid(), 'fee:test', $1, $2, 'platform',
                'consumer', 'platform', 10, 99
            )
            "#,
        )
        .bind(reserve.job_id.as_uuid())
        .bind(operation_id)
        .execute(&pool)
        .await
        .expect("recovery rows");

        let recovery = RecoveryService::new(database.clone());
        let worker = Uuid::new_v4();
        let external = recovery
            .claim_external_events(worker, 10, Duration::from_secs(1))
            .await
            .expect("external claim");
        assert_eq!(external.len(), 1);
        assert!(external[0].version.as_i64() > 1);
        let stale = recovery
            .complete_external_event(
                worker,
                external[0].external_event_id,
                darkbloom_coordinator_server::ledger::Version::new(1).expect("version"),
                darkbloom_coordinator_server::recovery::ExternalDisposition::Ignored,
            )
            .await;
        assert!(matches!(
            stale,
            Err(darkbloom_coordinator_server::ledger::LedgerError::StaleVersion)
        ));

        let outbox = recovery
            .claim_outbox(worker, 10, Duration::from_secs(1))
            .await
            .expect("outbox claim");
        assert_eq!(outbox.len(), 1);
        recovery
            .complete_outbox(
                worker,
                outbox[0].outbox_id,
                outbox[0].version,
                darkbloom_coordinator_server::recovery::OutboxDisposition::Delivered,
                Duration::ZERO,
            )
            .await
            .expect("outbox complete");
        let exhausted_outbox = Uuid::new_v4();
        sqlx::query(
            r#"
            INSERT INTO rust_coord.outbox (
                outbox_id, operation_key, payload_digest, kind, status,
                payload, max_attempts, owner_epoch
            ) VALUES (
                $1, 'outbox:exhausted', $2, 'external_call', 'pending',
                '{}', 1, 99
            )
            "#,
        )
        .bind(exhausted_outbox)
        .bind(digest(45).as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("exhausted outbox row");
        let exhausted = recovery
            .claim_outbox(worker, 1, Duration::from_secs(1))
            .await
            .expect("exhausted outbox claim");
        assert_eq!(exhausted.len(), 1);
        recovery
            .complete_outbox(
                worker,
                exhausted[0].outbox_id,
                exhausted[0].version,
                darkbloom_coordinator_server::recovery::OutboxDisposition::Retry,
                Duration::from_secs(1),
            )
            .await
            .expect("exhausted retry terminalizes");
        let exhausted_status: String =
            sqlx::query_scalar("SELECT status FROM rust_coord.outbox WHERE outbox_id = $1")
                .bind(exhausted_outbox)
                .fetch_one(&pool)
                .await
                .expect("exhausted outbox status");
        assert_eq!(exhausted_status, "failed");

        let projection = FeeProjectionService::new(database.clone());
        let fee_worker = Uuid::new_v4();
        let batch = projection
            .claim(
                "legacy-fees",
                fee_worker,
                10,
                Duration::from_secs(1),
            )
            .await
            .expect("fee claim");
        assert_eq!(batch.allocations.len(), 1);
        let mut stale_batch = batch.clone();
        stale_batch.allocations[0].version =
            darkbloom_coordinator_server::ledger::Version::new(
                u64::try_from(stale_batch.allocations[0].version.as_i64())
                    .expect("positive version")
                    + 1,
            )
            .expect("stale version");
        assert!(matches!(
            projection.complete(&stale_batch, fee_worker).await,
            Err(darkbloom_coordinator_server::ledger::LedgerError::StaleVersion)
        ));
        let still_processing: String = sqlx::query_scalar(
            "SELECT status FROM rust_coord.fee_allocations WHERE allocation_id = $1",
        )
        .bind(batch.allocations[0].allocation_id)
        .fetch_one(&pool)
        .await
        .expect("allocation after stale completion");
        assert_eq!(still_processing, "processing");
        projection
            .complete(&batch, fee_worker)
            .await
            .expect("fee complete");

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn catalog_loads_alias_build_version_and_account_price_in_one_snapshot() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            r#"
            INSERT INTO public.model_registry (
                id, display_name, max_context_length, max_output_length,
                capabilities, status, runtime_parameters
            ) VALUES (
                'model/build', 'Model', 4096, 512, ARRAY['text'], 'active',
                '{"temperature": 1}'
            )
            "#,
        )
        .execute(&pool)
        .await
        .expect("model registry");
        let version_id: i64 = sqlx::query_scalar(
            r#"
            INSERT INTO public.model_versions (
                model_id, version, r2_prefix, aggregate_sha256,
                total_size_bytes, file_count, status
            ) VALUES (
                'model/build', 'v1', 'models/v1', repeat('a', 64), 1, 1, 'ready'
            ) RETURNING id
            "#,
        )
        .fetch_one(&pool)
        .await
        .expect("model");
        sqlx::query(
            r#"
            INSERT INTO public.model_active_versions (model_id, model_version_id)
            VALUES ('model/build', $1)
            "#,
        )
        .bind(version_id)
        .execute(&pool)
        .await
        .expect("active model");
        sqlx::raw_sql(
            r#"
            INSERT INTO public.model_aliases (alias_id, desired_build)
            VALUES ('model', 'model/build');
            INSERT INTO public.model_prices (
                account_id, model, input_price, output_price
            ) VALUES
                ('platform', 'model/build', 10, 20),
                ('consumer', 'model/build', 30, 40)
            "#,
        )
        .execute(&pool)
        .await
        .expect("catalog rows");

        let snapshot = CatalogService::new(database.clone())
            .load("model", &account("consumer"))
            .await
            .expect("catalog snapshot");
        assert_eq!(snapshot.public_model.as_ref(), "model");
        assert_eq!(snapshot.concrete_model.as_str(), "model/build");
        assert!(snapshot.pricing_version.as_i64() > 0);
        assert_eq!(snapshot.input_micro_usd_per_million, amount(30));
        assert_eq!(snapshot.output_micro_usd_per_million, amount(40));
        sqlx::query(
            "UPDATE public.model_prices SET input_price = 31, updated_at = NOW() WHERE account_id = 'consumer' AND model = 'model/build'",
        )
        .execute(&pool)
        .await
        .expect("update account price");
        let updated = CatalogService::new(database.clone())
            .load("model", &account("consumer"))
            .await
            .expect("updated catalog snapshot");
        assert_ne!(updated.pricing_version, snapshot.pricing_version);
        assert_eq!(updated.input_micro_usd_per_million, amount(31));
        assert_eq!(updated.model_version.as_ref(), "v1");

        shutdown(database, ownership, pool).await;
    })
    .await;
}

async fn service_database(url: &str) -> (Database, CoordinatorOwnership, PgPool) {
    seed_service_schema(url).await;
    let database = Database::connect(url, 16, Duration::from_secs(5))
        .await
        .expect("database");
    let ownership = CoordinatorOwnership::configure(&database, url, true)
        .await
        .expect("ownership");
    let pool = PgPool::connect(url).await.expect("inspection pool");
    (database, ownership, pool)
}

async fn shutdown(database: Database, ownership: CoordinatorOwnership, pool: PgPool) {
    pool.close().await;
    database
        .close(Duration::from_secs(2))
        .await
        .expect("close database");
    ownership.release().await.expect("release ownership");
}

fn reserve_request(index: u8) -> ReserveRequest {
    ReserveRequest {
        operation: Operation::new(
            OperationKey::new(format!("reserve:recovery:{index}")).expect("key"),
            digest(index),
        ),
        job_id: JobId::random(),
        request_id: Uuid::new_v4(),
        reservation_id: ReservationId::random(),
        account_id: account("consumer"),
        api_key_id: "key".into(),
        amount: amount(100),
    }
}

fn digest(byte: u8) -> Digest {
    Digest::new([byte; 32])
}

fn account(value: &str) -> AccountId {
    AccountId::new(value).expect("account")
}

fn amount(value: u64) -> LedgerAmount {
    LedgerAmount::new(value).expect("amount")
}
