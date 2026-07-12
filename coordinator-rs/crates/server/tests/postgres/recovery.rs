use std::time::Duration;

use darkbloom_coordinator_core::ids::Digest;
use darkbloom_coordinator_server::{
    database::Database,
    db::catalog::CatalogService,
    ledger::{
        AccountId, JobId, LedgerAmount, LedgerError, LedgerService, Operation, OperationKey,
        RecoveryTerminalRecordResult, ReservationId, ReserveRequest, TerminalFacts, TerminalId,
        TerminalOutcome, Version,
    },
    ownership::CoordinatorOwnership,
    projection::FeeProjectionService,
    recovery::{JobRecoveryAction, RecoveryRuntime, RecoveryRuntimeConfig, RecoveryService},
};
use sqlx::PgPool;
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use super::support::{seed_service_schema, with_isolated_database};

const TEST_REQUEST_DEADLINE_EPOCH_MILLIS: u64 = 4_102_444_800_000;

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
async fn live_execution_lease_blocks_recovery_until_expiry() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('consumer', 1000, 1000)",
        )
        .execute(&pool)
        .await
        .expect("balance");
        let worker_id = Uuid::new_v4();
        let mut request = reserve_request(59);
        request.execution_worker_id = Some(worker_id);
        request.execution_lease_millis = Some(30_000);
        let job = LedgerService::new(database.clone())
            .reserve(&request)
            .await
            .expect("leased reserve");
        let recovery = RecoveryService::new(database.clone());
        assert!(
            recovery
                .claim_jobs(Uuid::new_v4(), 10, Duration::from_secs(1))
                .await
                .expect("claim around active execution")
                .is_empty()
        );
        LedgerService::new(database.clone())
            .renew_execution_lease(job.job_id, worker_id, Duration::from_secs(30))
            .await
            .expect("renew active execution");
        sqlx::query(
            "UPDATE rust_coord.inference_jobs SET lease_until = NOW() - INTERVAL '1 second' WHERE job_id = $1",
        )
        .bind(job.job_id.as_uuid())
        .execute(&pool)
        .await
        .expect("expire execution lease");
        let claimed = recovery
            .claim_jobs(Uuid::new_v4(), 10, Duration::from_secs(1))
            .await
            .expect("claim expired execution");
        assert_eq!(claimed.len(), 1);
        assert_eq!(claimed[0].job_id, job.job_id);

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn review_queues_are_never_claimed_or_version_bumped_by_recovery_polling() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('consumer', 10000, 10000)",
        )
        .execute(&pool)
        .await
        .expect("balance");
        let ledger = LedgerService::new(database.clone());
        let pending = ledger
            .reserve(&reserve_request(56))
            .await
            .expect("reserve review-pending job");
        sqlx::query(
            "UPDATE rust_coord.inference_jobs SET state = 'review_pending' WHERE job_id = $1",
        )
        .bind(pending.job_id.as_uuid())
        .execute(&pool)
        .await
        .expect("move job to operator review");

        let reviewed = ledger
            .reserve(&reserve_request(57))
            .await
            .expect("reserve reviewed job");
        let reviewed_attempt = Uuid::new_v4();
        let reviewed_provider = Uuid::new_v4();
        let reviewed_generation = Uuid::new_v4();
        sqlx::query(
            "UPDATE rust_coord.inference_jobs SET state = 'released_reviewed', terminal_at = NOW() WHERE job_id = $1",
        )
        .bind(reviewed.job_id.as_uuid())
        .execute(&pool)
        .await
        .expect("mark job reviewed");
        sqlx::query(
            r#"
            INSERT INTO rust_coord.inference_attempts (
                attempt_id, job_id, provider_id,
                provider_process_generation_id, session_epoch, owner_epoch,
                lease_id, permit_id, dispatch_nonce, request_digest, kind, state
            ) VALUES ($1, $2, $3, $4, 1, 1, $5, $6, $7, $8, 'primary', 'acknowledged')
            "#,
        )
        .bind(reviewed_attempt)
        .bind(reviewed.job_id.as_uuid())
        .bind(reviewed_provider)
        .bind(reviewed_generation)
        .bind(Uuid::new_v4())
        .bind(Uuid::new_v4())
        .bind(digest(70).as_bytes().as_slice())
        .bind(digest(71).as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("reviewed attempt");
        sqlx::query(
            r#"
            INSERT INTO rust_coord.provider_terminals (
                terminal_id, job_id, attempt_id, provider_id,
                provider_process_generation_id, origin_session_epoch,
                terminal_digest, raw_terminal, outcome, prompt_tokens,
                completion_tokens, reasoning_tokens, response_digest,
                rolling_digest, final_generated_tokens, provider_signature,
                status, owner_epoch, disposition_at
            ) VALUES (
                $1, $2, $3, $4, $5, 1, $6, '{}'::jsonb, 'cancelled',
                0, 0, 0, $7, $8, 0, '\x01'::bytea,
                'released_reviewed', 1, NOW()
            )
            "#,
        )
        .bind(Uuid::new_v4())
        .bind(reviewed.job_id.as_uuid())
        .bind(reviewed_attempt)
        .bind(reviewed_provider)
        .bind(reviewed_generation)
        .bind(digest(72).as_bytes().as_slice())
        .bind(digest(73).as_bytes().as_slice())
        .bind(digest(74).as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("reviewed terminal");

        let recovery = RecoveryService::new(database.clone());
        for _ in 0..4 {
            assert!(
                recovery
                    .claim_jobs(Uuid::new_v4(), 10, Duration::from_millis(10))
                    .await
                    .expect("poll jobs")
                    .is_empty()
            );
            assert!(
                recovery
                    .claim_terminals(Uuid::new_v4(), 10, Duration::from_millis(10))
                    .await
                    .expect("poll terminals")
                    .is_empty()
            );
        }
        let versions: Vec<(Uuid, i64)> = sqlx::query_as(
            "SELECT job_id, version FROM rust_coord.inference_jobs WHERE job_id IN ($1, $2) ORDER BY job_id",
        )
        .bind(pending.job_id.as_uuid())
        .bind(reviewed.job_id.as_uuid())
        .fetch_all(&pool)
        .await
        .expect("review job versions");
        assert!(versions.iter().all(|(_, version)| *version == 1));
        let attempt_version: i64 = sqlx::query_scalar(
            "SELECT version FROM rust_coord.inference_attempts WHERE attempt_id = $1",
        )
        .bind(reviewed_attempt)
        .fetch_one(&pool)
        .await
        .expect("review attempt version");
        assert_eq!(attempt_version, 1);
        let terminal_version: i64 = sqlx::query_scalar(
            "SELECT version FROM rust_coord.provider_terminals WHERE attempt_id = $1",
        )
        .bind(reviewed_attempt)
        .fetch_one(&pool)
        .await
        .expect("review terminal version");
        assert_eq!(terminal_version, 1);

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn recovery_releases_expired_not_sent_and_reviews_lost_queued_provider_state() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('consumer', 1000, 1000)",
        )
        .execute(&pool)
        .await
        .expect("balance");
        let ledger = LedgerService::new(database.clone());
        let not_sent = ledger
            .reserve(&reserve_request(54))
            .await
            .expect("reserve not-sent job");
        let queued = ledger
            .reserve(&reserve_request(55))
            .await
            .expect("reserve queued job");
        let not_sent_provider = Uuid::new_v4();
        let queued_provider = Uuid::new_v4();
        let not_sent_attempt = Uuid::new_v4();
        let queued_attempt = Uuid::new_v4();
        for (job_id, provider_id) in [
            (not_sent.job_id.as_uuid(), not_sent_provider),
            (queued.job_id.as_uuid(), queued_provider),
        ] {
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
                    request_digest = $3,
                    start_authorized_at = NOW() - INTERVAL '2 seconds',
                    start_deadline = NOW() - INTERVAL '1 second'
                WHERE job_id = $1
                "#,
            )
            .bind(job_id)
            .bind(provider_id)
            .bind(digest(75).as_bytes().as_slice())
            .execute(&pool)
            .await
            .expect("authorize recovery job");
        }
        for (job_id, attempt_id, provider_id, state) in [
            (
                not_sent.job_id.as_uuid(),
                not_sent_attempt,
                not_sent_provider,
                "not_sent",
            ),
            (
                queued.job_id.as_uuid(),
                queued_attempt,
                queued_provider,
                "queued",
            ),
        ] {
            sqlx::query(
                r#"
                INSERT INTO rust_coord.inference_attempts (
                    attempt_id, job_id, provider_id,
                    provider_process_generation_id, session_epoch, owner_epoch,
                    lease_id, permit_id, dispatch_nonce, request_digest, kind, state
                ) VALUES ($1, $2, $3, $4, 1, 1, $5, $6, $7, $8, 'primary', $9)
                "#,
            )
            .bind(attempt_id)
            .bind(job_id)
            .bind(provider_id)
            .bind(Uuid::new_v4())
            .bind(Uuid::new_v4())
            .bind(Uuid::new_v4())
            .bind(digest(76).as_bytes().as_slice())
            .bind(digest(75).as_bytes().as_slice())
            .bind(state)
            .execute(&pool)
            .await
            .expect("recovery attempt");
        }

        let runtime = RecoveryRuntime::new(
            database.clone(),
            None,
            RecoveryRuntimeConfig {
                batch_size: 4,
                lease_duration: Duration::from_millis(50),
                poll_interval: Duration::from_millis(5),
                outbox_retry_after: Duration::from_millis(10),
            },
        )
        .expect("recovery runtime");
        let cancellation = CancellationToken::new();
        let worker_cancellation = cancellation.clone();
        let worker = tokio::spawn(async move { runtime.run(worker_cancellation).await });
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            let states: Vec<String> = sqlx::query_scalar(
                "SELECT state FROM rust_coord.inference_jobs WHERE job_id IN ($1, $2) ORDER BY job_id",
            )
            .bind(not_sent.job_id.as_uuid())
            .bind(queued.job_id.as_uuid())
            .fetch_all(&pool)
            .await
            .expect("recovery states");
            if states.iter().any(|state| state == "released")
                && states.iter().any(|state| state == "review_pending")
            {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "recovery did not disposition expired delivery states: {states:?}"
            );
            sleep(Duration::from_millis(10)).await;
        }
        let not_sent_attempt_state: String = sqlx::query_scalar(
            "SELECT state FROM rust_coord.inference_attempts WHERE attempt_id = $1",
        )
        .bind(not_sent_attempt)
        .fetch_one(&pool)
        .await
        .expect("not-sent attempt state");
        assert_eq!(not_sent_attempt_state, "aborted");
        let queued_attempt_state: (String, bool) = sqlx::query_as(
            "SELECT state, worker_owner IS NOT NULL FROM rust_coord.inference_attempts WHERE attempt_id = $1",
        )
        .bind(queued_attempt)
        .fetch_one(&pool)
        .await
        .expect("queued attempt state");
        assert_eq!(queued_attempt_state.0, "queued");
        let hard_untrusted: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM rust_coord.provider_hard_untrust_epochs WHERE provider_id = $1 AND hard_untrust_epoch >= 1)",
        )
        .bind(queued_provider)
        .fetch_one(&pool)
        .await
        .expect("lost provider hard-untrust");
        assert!(hard_untrusted);
        let balance: i64 = sqlx::query_scalar(
            "SELECT balance_micro_usd FROM public.balances WHERE account_id = 'consumer'",
        )
        .fetch_one(&pool)
        .await
        .expect("recovery balance");
        assert_eq!(balance, 900, "only the not-sent reservation was released");

        cancellation.cancel();
        tokio::time::timeout(Duration::from_secs(2), worker)
            .await
            .expect("bounded recovery shutdown")
            .expect("recovery task join")
            .expect("recovery runtime result");
        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn authorized_recovery_claim_is_retained_instead_of_hot_looped() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('consumer', 1000, 1000)",
        )
        .execute(&pool)
        .await
        .expect("balance");
        let job = LedgerService::new(database.clone())
            .reserve(&reserve_request(58))
            .await
            .expect("reserve authorized recovery job");
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let request_digest = digest(58);
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
        .bind(job.job_id.as_uuid())
        .bind(provider_id)
        .bind(request_digest.as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("authorize recovery job");
        sqlx::query(
            r#"
            INSERT INTO rust_coord.inference_attempts (
                attempt_id, job_id, provider_id,
                provider_process_generation_id, session_epoch, owner_epoch,
                lease_id, permit_id, dispatch_nonce, request_digest, kind, state
            ) VALUES ($1, $2, $3, $4, 1, 1, $5, $6, $7, $8, 'primary', 'started')
            "#,
        )
        .bind(Uuid::new_v4())
        .bind(job.job_id.as_uuid())
        .bind(provider_id)
        .bind(generation_id)
        .bind(Uuid::new_v4())
        .bind(Uuid::new_v4())
        .bind(digest(59).as_bytes().as_slice())
        .bind(request_digest.as_bytes().as_slice())
        .execute(&pool)
        .await
        .expect("authorized recovery attempt");

        let runtime = RecoveryRuntime::new(
            database.clone(),
            None,
            RecoveryRuntimeConfig {
                batch_size: 4,
                lease_duration: Duration::from_secs(1),
                poll_interval: Duration::from_millis(10),
                outbox_retry_after: Duration::from_millis(10),
            },
        )
        .expect("recovery runtime");
        let cancellation = CancellationToken::new();
        let worker_cancellation = cancellation.clone();
        let worker = tokio::spawn(async move { runtime.run(worker_cancellation).await });
        sleep(Duration::from_millis(80)).await;
        let (version, leased): (i64, bool) = sqlx::query_as(
            r#"
            SELECT version, worker_owner IS NOT NULL AND lease_until > NOW()
            FROM rust_coord.inference_jobs
            WHERE job_id = $1
            "#,
        )
        .bind(job.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("inspect retained authorized recovery lease");
        assert_eq!(version, 2, "authorized job was repeatedly re-claimed");
        assert!(leased, "authorized recovery claim was released prematurely");

        cancellation.cancel();
        tokio::time::timeout(Duration::from_secs(2), worker)
            .await
            .expect("bounded recovery shutdown")
            .expect("recovery task join")
            .expect("recovery runtime result");
        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn recovery_supervisor_cancels_and_joins_every_worker_lane() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        let runtime = RecoveryRuntime::new(
            database.clone(),
            None,
            RecoveryRuntimeConfig {
                batch_size: 4,
                lease_duration: Duration::from_secs(1),
                poll_interval: Duration::from_millis(10),
                outbox_retry_after: Duration::from_millis(10),
            },
        )
        .expect("recovery runtime");
        let cancellation = CancellationToken::new();
        let worker_cancellation = cancellation.clone();
        let worker = tokio::spawn(async move { runtime.run(worker_cancellation).await });
        sleep(Duration::from_millis(30)).await;
        cancellation.cancel();
        tokio::time::timeout(Duration::from_secs(2), worker)
            .await
            .expect("bounded recovery shutdown")
            .expect("recovery task join")
            .expect("recovery runtime result");

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
        let recovery = RecoveryService::new(database.clone());
        let job_worker = Uuid::new_v4();
        let leases = recovery
            .claim_jobs(job_worker, 10, Duration::from_secs(1))
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
        let terminal_id = TerminalId::new(Uuid::new_v4()).expect("terminal id");
        let recorded = ledger
            .record_terminal_for_recovery(&TerminalFacts {
                terminal_id,
                attempt_id: darkbloom_coordinator_server::ledger::AttemptId::new(attempt_id)
                    .expect("attempt id"),
                provider_id,
                provider_process_generation_id: generation_id,
                origin_session_epoch: Version::new(1).expect("session epoch"),
                terminal_digest: digest(65),
                raw_terminal: serde_json::json!({}),
                outcome: TerminalOutcome::Completed,
                error_class: None,
                prompt_tokens: 1,
                completion_tokens: 1,
                reasoning_tokens: 0,
                response_digest: digest(66),
                rolling_digest: digest(67),
                final_generated_tokens: 1,
                provider_signature: vec![1],
                recovery_lease: None,
            })
            .await
            .expect("record terminal during job recovery claim");
        assert_eq!(
            recorded,
            RecoveryTerminalRecordResult::Pending {
                job_id: authorized_job
            }
        );
        let terminals = recovery
            .claim_terminals(Uuid::new_v4(), 10, Duration::from_secs(1))
            .await
            .expect("terminal claim");
        assert_eq!(terminals.len(), 1);
        assert_eq!(terminals[0].terminal_id, terminal_id);
        assert!(matches!(
            recovery
                .disposition_terminal(&ledger, terminals[0].clone())
                .await,
            Err(LedgerError::TerminalReview(
                "terminal completion exceeds the durable accepted checkpoint"
            ))
        ));

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
async fn catalog_loads_alias_build_version_and_platform_price_in_one_snapshot() {
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
            .load("model")
            .await
            .expect("catalog snapshot");
        assert_eq!(snapshot.public_model.as_ref(), "model");
        assert_eq!(snapshot.concrete_model.as_str(), "model/build");
        assert!(snapshot.pricing_version.as_i64() > 0);
        assert_eq!(snapshot.input_micro_usd_per_million, amount(10));
        assert_eq!(snapshot.output_micro_usd_per_million, amount(20));
        sqlx::query(
            "UPDATE public.model_prices SET input_price = 31, updated_at = NOW() WHERE account_id = 'consumer' AND model = 'model/build'",
        )
        .execute(&pool)
        .await
        .expect("update consumer price");
        let consumer_updated = CatalogService::new(database.clone())
            .load("model")
            .await
            .expect("consumer-updated catalog snapshot");
        assert_eq!(consumer_updated.pricing_version, snapshot.pricing_version);
        assert_eq!(consumer_updated.input_micro_usd_per_million, amount(10));
        assert_eq!(consumer_updated.output_micro_usd_per_million, amount(20));

        sqlx::query(
            "UPDATE public.model_prices SET input_price = 11, updated_at = NOW() WHERE account_id = 'platform' AND model = 'model/build'",
        )
        .execute(&pool)
        .await
        .expect("update platform price");
        let updated = CatalogService::new(database.clone())
            .load("model")
            .await
            .expect("platform-updated catalog snapshot");
        assert_ne!(updated.pricing_version, snapshot.pricing_version);
        assert_eq!(updated.input_micro_usd_per_million, amount(11));
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
        consumer_key_hash: "consumer-key-hash".into(),
        amount: amount(100),
        request_deadline_epoch_millis: TEST_REQUEST_DEADLINE_EPOCH_MILLIS,
        execution_worker_id: None,
        execution_lease_millis: None,
        provisional_provider_id: None,
        provisional_session_epoch: None,
        public_model: "".into(),
        concrete_model: "".into(),
        api_key_limit_micro_usd: None,
        api_key_controlled: false,
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
