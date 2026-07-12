use std::{
    ffi::OsString,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use darkbloom_coordinator_core::ids::Digest;
use darkbloom_coordinator_server::{
    database::Database,
    ledger::{
        AccountId, AttemptId, AttemptState, DurableAttemptIdentity, DurableAttemptKind,
        DurableTerminalDisposition, ExternalEventId, ExternalId, JobId, JobState, LedgerAmount,
        LedgerError, LedgerService, MutationDisposition, Operation, OperationKey,
        PreparedReservation, RecoveryTerminalRecordResult, ReleaseRequest, ReservationId,
        ReserveRequest, ReviewDisposition, ReviewResolutionRequest, SettleRequest,
        StartDispatchDisposition, StartDispatchRequest, StripeDeposit, TerminalFacts, TerminalId,
        TerminalLookup, TerminalOutcome, TerminalReleaseRequest, Version, WithdrawalDisposition,
        WithdrawalId, WithdrawalRequest, WithdrawalStatus, WithdrawalTransition,
        canonical_json_digest,
    },
    operator::OperatorCommand,
    ownership::CoordinatorOwnership,
    recovery::{RecoveryRuntime, RecoveryRuntimeConfig, RecoveryService},
};
use serde_json::json;
use sqlx::{PgPool, types::Json};
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use super::support::{seed_service_schema, with_isolated_database};

const TEST_REQUEST_DEADLINE_EPOCH_MILLIS: u64 = 4_102_444_800_000;

#[tokio::test]
async fn reservation_replay_conflict_and_mixed_provenance_release() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 100_000, 70_000).await;
        let service = LedgerService::new(database.clone());
        let reserve = reserve_request("reserve:mixed", 1, "consumer", 80_000);

        let applied = service.reserve(&reserve).await.expect("reserve");
        assert_eq!(applied.disposition, MutationDisposition::Applied);
        assert_eq!(applied.withdrawable, amount(50_000));
        assert_eq!(balance(&pool, "consumer").await, (20_000, 20_000));

        let replay = service.reserve(&reserve).await.expect("reserve replay");
        assert_eq!(replay.disposition, MutationDisposition::Replayed);
        assert_eq!(balance(&pool, "consumer").await, (20_000, 20_000));
        let commit_unknown_resolution = service
            .reconcile_reserve(&reserve)
            .await
            .expect("resolve committed reserve");
        assert_eq!(
            commit_unknown_resolution.disposition,
            MutationDisposition::Replayed
        );
        let absent = reserve_request("reserve:never-committed", 98, "consumer", 1);
        assert!(matches!(
            service.reconcile_reserve(&absent).await,
            Err(LedgerError::CommitOutcomeUnknown { operation, .. })
                if operation == absent.operation.key
        ));

        let mut conflict = reserve.clone();
        conflict.operation.digest = digest(99);
        assert!(matches!(
            service.reserve(&conflict).await,
            Err(LedgerError::OperationConflict)
        ));

        let released = service
            .release(&ReleaseRequest {
                operation: operation("release:mixed", 2),
                job_id: reserve.job_id,
                expected_version: applied.version,
                expected_state: JobState::Reserved,
                reason: "test release".into(),
            })
            .await
            .expect("release");
        assert_eq!(released.state, JobState::Released);
        assert_eq!(balance(&pool, "consumer").await, (100_000, 70_000));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn api_key_spend_limit_is_an_atomic_reservation_cas_and_rejects_stale_controls() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 1_000).await;
        sqlx::query(
            r#"
            INSERT INTO public.api_keys (
                key_hash, raw_prefix, owner_account_id, id, name,
                limit_micro_usd, active
            ) VALUES (
                'consumer-key-hash', 'consumer-', 'consumer', 'api-key',
                'controlled key', 100, TRUE
            )
            "#,
        )
        .execute(&pool)
        .await
        .expect("seed controlled API key");
        let service = LedgerService::new(database.clone());
        let provider_fence = Uuid::new_v4();
        let mut first = reserve_request("reserve:key-limit:first", 111, "consumer", 60);
        first.api_key_limit_micro_usd = Some(100);
        first.api_key_controlled = true;
        first.provisional_provider_id = Some(provider_fence);
        first.provisional_session_epoch = Some(version(1));
        first.public_model = Arc::from("model");
        first.concrete_model = Arc::from("model/build");
        let mut second = reserve_request("reserve:key-limit:second", 112, "consumer", 60);
        second.api_key_limit_micro_usd = Some(100);
        second.api_key_controlled = true;
        second.provisional_provider_id = Some(provider_fence);
        second.provisional_session_epoch = Some(version(1));
        second.public_model = Arc::from("model");
        second.concrete_model = Arc::from("model/build");

        let (first_result, second_result) =
            tokio::join!(service.reserve(&first), service.reserve(&second));
        let results = [first_result, second_result];
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, Err(LedgerError::ApiKeyControlRejected)))
                .count(),
            1
        );
        assert_eq!(balance(&pool, "consumer").await, (940, 940));
        let jobs: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM rust_coord.inference_jobs WHERE api_key_id='api-key'",
        )
        .fetch_one(&pool)
        .await
        .expect("controlled job count");
        assert_eq!(jobs, 1);

        let (controlled_job_id, controlled_version): (Uuid, i64) = sqlx::query_as(
            r#"
            SELECT job_id, version
            FROM rust_coord.inference_jobs
            WHERE api_key_id = 'api-key'
            "#,
        )
        .fetch_one(&pool)
        .await
        .expect("controlled durable job");
        let controlled_job_id = JobId::new(controlled_job_id).expect("controlled job id");
        let controlled_provider_id = Uuid::new_v4();
        let controlled_prepared = standard_prepared(
            "resize:key-limit:first",
            115,
            controlled_job_id,
            version(u64::try_from(controlled_version).expect("positive controlled version")),
            AttemptId::random(),
            controlled_provider_id,
            Uuid::new_v4(),
        );
        assert!(matches!(
            service.resize_and_authorize(&controlled_prepared).await,
            Err(LedgerError::ApiKeySpendLimitExceeded)
        ));

        sqlx::query("UPDATE public.api_keys SET limit_micro_usd=400 WHERE id='api-key'")
            .execute(&pool)
            .await
            .expect("raise controlled key limit");
        let authorized = service
            .resize_and_authorize(&controlled_prepared)
            .await
            .expect("authorize within raised key limit");
        assert_eq!(authorized.total, amount(300));
        let tracked_reservation: i64 = sqlx::query_scalar(
            "SELECT api_key_reserved_micro_usd FROM rust_coord.inference_jobs WHERE job_id=$1",
        )
        .bind(controlled_job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("tracked controlled reservation");
        assert_eq!(tracked_reservation, 300);

        let mut concurrent_resize =
            reserve_request("reserve:key-limit:resize-race", 116, "consumer", 60);
        concurrent_resize.api_key_limit_micro_usd = Some(400);
        concurrent_resize.api_key_controlled = true;
        concurrent_resize.provisional_provider_id = Some(provider_fence);
        concurrent_resize.provisional_session_epoch = Some(version(1));
        concurrent_resize.public_model = Arc::from("model");
        concurrent_resize.concrete_model = Arc::from("model/build");
        let concurrent_reserved = service
            .reserve(&concurrent_resize)
            .await
            .expect("reserve remaining controlled capacity");
        let concurrent_prepared = standard_prepared(
            "resize:key-limit:resize-race",
            117,
            concurrent_resize.job_id,
            concurrent_reserved.version,
            AttemptId::random(),
            Uuid::new_v4(),
            Uuid::new_v4(),
        );
        assert!(matches!(
            service.resize_and_authorize(&concurrent_prepared).await,
            Err(LedgerError::ApiKeySpendLimitExceeded)
        ));
        sqlx::query(
            "UPDATE public.api_keys SET limit_micro_usd=1000, allowed_models='[\"another/model\"]' WHERE id='api-key'",
        )
        .execute(&pool)
        .await
        .expect("make resize model control stale");
        assert!(matches!(
            service.resize_and_authorize(&concurrent_prepared).await,
            Err(LedgerError::ApiKeyControlRejected)
        ));
        sqlx::query(
            "UPDATE public.api_keys SET allowed_models='[]', self_route_only=TRUE WHERE id='api-key'",
        )
        .execute(&pool)
        .await
        .expect("make resize route control stale");
        assert!(matches!(
            service.resize_and_authorize(&concurrent_prepared).await,
            Err(LedgerError::ApiKeyControlRejected)
        ));
        sqlx::query(
            "UPDATE public.api_keys SET self_route_only=FALSE, active=FALSE WHERE id='api-key'",
        )
        .execute(&pool)
        .await
        .expect("revoke key before resize");
        assert!(matches!(
            service.resize_and_authorize(&concurrent_prepared).await,
            Err(LedgerError::ApiKeyControlRejected)
        ));
        sqlx::query(
            "UPDATE public.api_keys SET active=TRUE, expires_at=NOW() - INTERVAL '1 second' WHERE id='api-key'",
        )
        .execute(&pool)
        .await
        .expect("expire key before resize");
        assert!(matches!(
            service.resize_and_authorize(&concurrent_prepared).await,
            Err(LedgerError::ApiKeyControlRejected)
        ));
        sqlx::query(
            "UPDATE public.api_keys SET limit_micro_usd=400, expires_at=NULL, allowed_models='[]', self_route_only=FALSE WHERE id='api-key'",
        )
        .execute(&pool)
        .await
        .expect("restore key controls");

        let mut stale_limit = reserve_request("reserve:key-limit:stale", 113, "consumer", 1);
        stale_limit.api_key_limit_micro_usd = Some(101);
        stale_limit.api_key_controlled = true;
        stale_limit.provisional_provider_id = Some(provider_fence);
        stale_limit.provisional_session_epoch = Some(version(1));
        stale_limit.public_model = Arc::from("model");
        stale_limit.concrete_model = Arc::from("model/build");
        assert!(matches!(
            service.reserve(&stale_limit).await,
            Err(LedgerError::ApiKeyControlRejected)
        ));

        sqlx::query(
            r#"
            UPDATE public.api_keys
            SET allowed_models='["another/model"]', self_route_only=FALSE
            WHERE id='api-key'
            "#,
        )
        .execute(&pool)
        .await
        .expect("change allowed model before reserve");
        let mut stale_model = reserve_request("reserve:key-limit:stale-model", 118, "consumer", 1);
        stale_model.api_key_limit_micro_usd = Some(400);
        stale_model.api_key_controlled = true;
        stale_model.provisional_provider_id = Some(provider_fence);
        stale_model.provisional_session_epoch = Some(version(1));
        stale_model.public_model = Arc::from("model");
        stale_model.concrete_model = Arc::from("model/build");
        assert!(matches!(
            service.reserve(&stale_model).await,
            Err(LedgerError::ApiKeyControlRejected)
        ));
        assert_eq!(balance(&pool, "consumer").await, (640, 640));

        sqlx::query(
            r#"
            UPDATE public.api_keys
            SET allowed_models='["model/build"]', self_route_only=TRUE
            WHERE id='api-key'
            "#,
        )
        .execute(&pool)
        .await
        .expect("enable self-route key");
        sqlx::query(
            r#"
            INSERT INTO public.providers (
                id, hardware, models, backend, account_id, connected,
                session_id, session_epoch, trust_level
            ) VALUES (
                $1, '{}'::JSONB, '[]'::JSONB, 'mlx',
                'another-account', TRUE, 'self-route-session', 1, 'hardware'
            )
            "#,
        )
        .bind(provider_fence.to_string())
        .execute(&pool)
        .await
        .expect("seed wrong-owner provider");
        let mut wrong_owner = reserve_request("reserve:key-limit:wrong-owner", 119, "consumer", 1);
        wrong_owner.api_key_limit_micro_usd = Some(400);
        wrong_owner.api_key_controlled = true;
        wrong_owner.provisional_provider_id = Some(provider_fence);
        wrong_owner.provisional_session_epoch = Some(version(1));
        wrong_owner.public_model = Arc::from("model");
        wrong_owner.concrete_model = Arc::from("model/build");
        assert!(matches!(
            service.reserve(&wrong_owner).await,
            Err(LedgerError::ApiKeyControlRejected)
        ));
        sqlx::query("UPDATE public.providers SET account_id='consumer' WHERE id=$1")
            .bind(provider_fence.to_string())
            .execute(&pool)
            .await
            .expect("bind selected provider to key owner");
        let owned = service
            .reserve(&wrong_owner)
            .await
            .expect("exact owner provider admits before debit");
        service
            .release(&ReleaseRequest {
                operation: operation("release:key-limit:owner", 120),
                job_id: wrong_owner.job_id,
                expected_version: owned.version,
                expected_state: owned.state,
                reason: Arc::from("test release"),
            })
            .await
            .expect("release owner-pinned reservation");
        assert_eq!(balance(&pool, "consumer").await, (640, 640));

        sqlx::query("UPDATE public.api_keys SET active=FALSE WHERE id='api-key'")
            .execute(&pool)
            .await
            .expect("revoke controlled key");
        let mut revoked = reserve_request("reserve:key-limit:revoked", 114, "consumer", 1);
        revoked.api_key_limit_micro_usd = Some(100);
        revoked.api_key_controlled = true;
        revoked.provisional_provider_id = Some(provider_fence);
        revoked.provisional_session_epoch = Some(version(1));
        revoked.public_model = Arc::from("model");
        revoked.concrete_model = Arc::from("model/build");
        assert!(matches!(
            service.reserve(&revoked).await,
            Err(LedgerError::ApiKeyControlRejected)
        ));
        assert_eq!(balance(&pool, "consumer").await, (640, 640));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn authorization_timeout_and_blocked_reconciliation_report_unknown_outcome() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) =
            service_database_with_timeout(&url, Duration::from_millis(100)).await;
        seed_balance(&pool, "consumer", 1_000, 1_000).await;
        let service = LedgerService::new(database.clone());
        let reserve = reserve_request("reserve:authorize-timeout", 75, "consumer", 300);
        let reserved = service.reserve(&reserve).await.expect("reserve");
        let attempt_id = AttemptId::random();
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let prepared = standard_prepared(
            "resize:authorize-timeout",
            76,
            reserve.job_id,
            reserved.version,
            attempt_id,
            provider_id,
            generation_id,
        );

        let mut blocker = pool.begin().await.expect("begin reconciliation blocker");
        sqlx::query("LOCK TABLE rust_coord.financial_operations IN ACCESS EXCLUSIVE MODE")
            .execute(&mut *blocker)
            .await
            .expect("lock operation journal");
        let error = service
            .resize_and_authorize(&prepared)
            .await
            .expect_err("authorization must remain ambiguous");
        match error {
            LedgerError::CommitOutcomeUnknown {
                operation,
                diagnostic,
            } => {
                assert_eq!(operation, prepared.operation.key);
                assert!(
                    diagnostic.contains("reconciliation query failed"),
                    "missing reconciliation source: {diagnostic}"
                );
            }
            other => panic!("unexpected authorization error: {other:?}"),
        }
        blocker.rollback().await.expect("release blocker");

        let durable: (String, i64) = sqlx::query_as(
            "SELECT state, version FROM rust_coord.inference_jobs WHERE job_id = $1",
        )
        .bind(reserve.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("durable job after ambiguous authorization");
        assert_eq!(durable, ("reserved".to_owned(), reserved.version.as_i64()));
        let attempts: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM rust_coord.inference_attempts WHERE job_id = $1",
        )
        .bind(reserve.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("attempts after ambiguous authorization");
        assert_eq!(attempts, 0);

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn started_job_times_out_to_review_and_operator_release_is_once_only() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 1_000).await;
        let service = LedgerService::new(database.clone());
        let mut request = reserve_request("reserve:terminal-deadline", 180, "consumer", 300);
        request.request_deadline_epoch_millis = current_epoch_millis() + 600;
        let reserved = service.reserve(&request).await.expect("reserve");
        let stored_deadline: i64 = sqlx::query_scalar(
            "SELECT (EXTRACT(EPOCH FROM request_deadline) * 1000)::BIGINT FROM rust_coord.inference_jobs WHERE job_id = $1",
        )
        .bind(request.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("stored request deadline");
        assert_eq!(
            stored_deadline,
            i64::try_from(request.request_deadline_epoch_millis).expect("test deadline fits i64")
        );

        let attempt_id = AttemptId::random();
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let authorized = service
            .resize_and_authorize(&standard_prepared(
                "resize:terminal-deadline",
                181,
                request.job_id,
                reserved.version,
                attempt_id,
                provider_id,
                generation_id,
            ))
            .await
            .expect("authorize");
        let queued = service
            .record_start_dispatch(&StartDispatchRequest {
                job_id: request.job_id,
                expected_job_version: authorized.version,
                expected_job_state: JobState::StartAuthorized,
                attempt_id,
                expected_attempt_version: version(1),
                expected_attempt_state: AttemptState::NotSent,
                disposition: StartDispatchDisposition::Queued,
            })
            .await
            .expect("queue start");
        let on_wire = service
            .record_start_dispatch(&StartDispatchRequest {
                job_id: request.job_id,
                expected_job_version: queued.job_version,
                expected_job_state: queued.job_state,
                attempt_id,
                expected_attempt_version: queued.attempt_version,
                expected_attempt_state: queued.attempt_state,
                disposition: StartDispatchDisposition::OnWire,
            })
            .await
            .expect("write start");
        service
            .record_start_dispatch(&StartDispatchRequest {
                job_id: request.job_id,
                expected_job_version: on_wire.job_version,
                expected_job_state: on_wire.job_state,
                attempt_id,
                expected_attempt_version: on_wire.attempt_version,
                expected_attempt_state: on_wire.attempt_state,
                disposition: StartDispatchDisposition::Running,
            })
            .await
            .expect("record StartAck");

        let runtime = RecoveryRuntime::new(
            database.clone(),
            None,
            RecoveryRuntimeConfig {
                batch_size: 4,
                lease_duration: Duration::from_millis(30),
                poll_interval: Duration::from_millis(5),
                outbox_retry_after: Duration::from_millis(10),
            },
        )
        .expect("recovery runtime");
        let cancellation = CancellationToken::new();
        let worker_cancellation = cancellation.clone();
        let worker = tokio::spawn(async move { runtime.run(worker_cancellation).await });

        let claim_deadline = tokio::time::Instant::now() + Duration::from_millis(200);
        let claimed_version = loop {
            let row: (i64, bool) = sqlx::query_as(
                "SELECT version, worker_owner IS NOT NULL FROM rust_coord.inference_jobs WHERE job_id = $1",
            )
            .bind(request.job_id.as_uuid())
            .fetch_one(&pool)
            .await
            .expect("started recovery state");
            if row.1 {
                break row.0;
            }
            assert!(
                tokio::time::Instant::now() < claim_deadline,
                "started job was not claimed"
            );
            sleep(Duration::from_millis(5)).await;
        };
        sleep(Duration::from_millis(100)).await;
        let before_deadline: (String, i64, i64) = sqlx::query_as(
            "SELECT state, version, reserved_total_micro_usd FROM rust_coord.inference_jobs WHERE job_id = $1",
        )
        .bind(request.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("pre-deadline state");
        assert_eq!(before_deadline.0, "running");
        assert_eq!(
            before_deadline.1, claimed_version,
            "pre-deadline polls repeatedly rewrote the recovery claim"
        );
        assert_eq!(before_deadline.2, 300);
        assert_eq!(balance(&pool, "consumer").await, (700, 700));

        let review_deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            let state: String =
                sqlx::query_scalar("SELECT state FROM rust_coord.inference_jobs WHERE job_id = $1")
                    .bind(request.job_id.as_uuid())
                    .fetch_one(&pool)
                    .await
                    .expect("terminal deadline state");
            if state == "review_pending" {
                break;
            }
            assert!(
                tokio::time::Instant::now() < review_deadline,
                "started job did not enter review after its terminal deadline"
            );
            sleep(Duration::from_millis(10)).await;
        }
        let review_facts: (String, i64, String, Uuid, Vec<u8>) = sqlx::query_as(
            "SELECT error_class, reserved_total_micro_usd, concrete_model, provider_id, request_digest FROM rust_coord.inference_jobs WHERE job_id = $1",
        )
        .bind(request.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("review facts");
        assert_eq!(review_facts.0, "authorized_terminal_timeout");
        assert_eq!(review_facts.1, 300);
        assert_eq!(review_facts.2, "model/build");
        assert_eq!(review_facts.3, provider_id);
        assert_eq!(review_facts.4, digest(183).as_bytes());
        assert_eq!(balance(&pool, "consumer").await, (700, 700));

        cancellation.cancel();
        tokio::time::timeout(Duration::from_secs(2), worker)
            .await
            .expect("bounded recovery shutdown")
            .expect("recovery task join")
            .expect("recovery runtime result");

        let resolution = ReviewResolutionRequest {
            operation: operation("review:terminal-timeout:release", 182),
            job_id: request.job_id,
            disposition: ReviewDisposition::Release,
            operator_reason: "provider disappeared after StartAck".into(),
        };
        let applied = service
            .resolve_review(&resolution)
            .await
            .expect("operator release");
        assert_eq!(applied.disposition, MutationDisposition::Applied);
        let replayed = service
            .resolve_review(&resolution)
            .await
            .expect("operator release replay");
        assert_eq!(replayed.disposition, MutationDisposition::Replayed);
        assert_eq!(balance(&pool, "consumer").await, (1_000, 1_000));
        let counts: (i64, i64) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM rust_coord.financial_operations WHERE job_id = $1 AND kind = 'release'), (SELECT COUNT(*) FROM rust_coord.review_resolution_journal WHERE job_id = $1)",
        )
        .bind(request.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("review disposition counts");
        assert_eq!(counts, (1, 1));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn late_terminal_after_authorized_timeout_can_be_settled_only_by_review() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 1_000).await;
        let service = LedgerService::new(database.clone());
        let mut request = reserve_request("reserve:late-terminal-review", 188, "consumer", 300);
        request.request_deadline_epoch_millis = current_epoch_millis() + 100;
        let reserved = service.reserve(&request).await.expect("reserve");
        let attempt_id = AttemptId::random();
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let authorized = service
            .resize_and_authorize(&standard_prepared(
                "resize:late-terminal-review",
                189,
                request.job_id,
                reserved.version,
                attempt_id,
                provider_id,
                generation_id,
            ))
            .await
            .expect("authorize");
        let queued = service
            .record_start_dispatch(&StartDispatchRequest {
                job_id: request.job_id,
                expected_job_version: authorized.version,
                expected_job_state: JobState::StartAuthorized,
                attempt_id,
                expected_attempt_version: version(1),
                expected_attempt_state: AttemptState::NotSent,
                disposition: StartDispatchDisposition::Queued,
            })
            .await
            .expect("queue start");
        let on_wire = service
            .record_start_dispatch(&StartDispatchRequest {
                job_id: request.job_id,
                expected_job_version: queued.job_version,
                expected_job_state: queued.job_state,
                attempt_id,
                expected_attempt_version: queued.attempt_version,
                expected_attempt_state: queued.attempt_state,
                disposition: StartDispatchDisposition::OnWire,
            })
            .await
            .expect("write start");
        let running = service
            .record_start_dispatch(&StartDispatchRequest {
                job_id: request.job_id,
                expected_job_version: on_wire.job_version,
                expected_job_state: on_wire.job_state,
                attempt_id,
                expected_attempt_version: on_wire.attempt_version,
                expected_attempt_state: on_wire.attempt_state,
                disposition: StartDispatchDisposition::Running,
            })
            .await
            .expect("record StartAck");
        sleep(Duration::from_millis(120)).await;

        let terminal = TerminalFacts {
            terminal_id: TerminalId::random(),
            attempt_id,
            provider_id,
            provider_process_generation_id: generation_id,
            origin_session_epoch: version(1),
            terminal_digest: digest(190),
            raw_terminal: json!({"late": true}),
            outcome: TerminalOutcome::Completed,
            error_class: None,
            prompt_tokens: 100,
            completion_tokens: 0,
            reasoning_tokens: 0,
            response_digest: digest(191),
            rolling_digest: digest(192),
            final_generated_tokens: 0,
            provider_signature: vec![1],
            recovery_lease: None,
        };
        assert!(matches!(
            service
                .settle(&SettleRequest {
                    operation: operation("settle:late-terminal:automatic", 194),
                    job_id: request.job_id,
                    expected_job_version: running.job_version,
                    expected_job_state: running.job_state,
                    expected_attempt_version: running.attempt_version,
                    terminal: terminal.clone(),
                    consumer_charge: amount(100),
                    provider_payout: amount(75),
                    platform_fee: amount(20),
                    referral_reward: amount(5),
                    accepted_cumulative_tokens: 0,
                    consumer_key_hash: "consumer-key-hash".into(),
                    review: None,
                })
                .await,
            Err(LedgerError::OperationConflict)
        ));
        assert_eq!(balance(&pool, "consumer").await, (700, 700));
        assert_eq!(
            service
                .record_terminal_for_recovery(&terminal)
                .await
                .expect("record late terminal"),
            RecoveryTerminalRecordResult::Pending {
                job_id: request.job_id
            }
        );
        let (state, error_class): (String, Option<String>) = sqlx::query_as(
            "SELECT state, error_class FROM rust_coord.inference_jobs WHERE job_id = $1",
        )
        .bind(request.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("late terminal job state");
        assert_eq!(state, "review_pending");
        assert_eq!(error_class.as_deref(), Some("authorized_terminal_timeout"));

        let resolution = ReviewResolutionRequest {
            operation: operation("review:late-terminal:settle", 193),
            job_id: request.job_id,
            disposition: ReviewDisposition::Settle,
            operator_reason: "validated terminal received after durable deadline".into(),
        };
        let settled = service
            .resolve_review(&resolution)
            .await
            .expect("review settlement");
        assert_eq!(settled.state, JobState::SettledReviewed);
        assert_eq!(settled.disposition, MutationDisposition::Applied);
        assert_eq!(
            service
                .resolve_review(&resolution)
                .await
                .expect("review settlement replay")
                .disposition,
            MutationDisposition::Replayed
        );
        assert_eq!(balance(&pool, "consumer").await, (900, 900));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn balance_overflow_fails_closed_without_partial_deposit() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::raw_sql(
            r#"
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES ('consumer', 9223372036854775807, 0);
            INSERT INTO public.billing_sessions (
                id, account_id, payment_method, amount_micro_usd
            ) VALUES ('billing-overflow', 'consumer', 'stripe', 1)
            "#,
        )
        .execute(&pool)
        .await
        .expect("overflow fixtures");
        let deposit = StripeDeposit {
            operation: operation("deposit:overflow", 101),
            external_event_id: ExternalEventId::random(),
            event_id: external("evt-overflow"),
            checkout_session_id: external("cs-overflow"),
            billing_session_id: external("billing-overflow"),
            payload_digest: canonical_json_digest(&json!({"id": "evt-overflow"}))
                .expect("payload digest"),
            payload: json!({"id": "evt-overflow"}),
            currency: "usd".into(),
            amount: amount(1),
        };
        assert!(matches!(
            LedgerService::new(database.clone()).deposit(&deposit).await,
            Err(LedgerError::OperationConflict)
        ));
        assert_eq!(
            balance(&pool, "consumer").await,
            (i64::MAX, 0),
            "overflow changed the balance"
        );
        let operation_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM rust_coord.financial_operations WHERE operation_key = $1",
        )
        .bind(deposit.operation.key.as_str())
        .fetch_one(&pool)
        .await
        .expect("operation count");
        let event_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM public.stripe_deposit_events")
                .fetch_one(&pool)
                .await
                .expect("event count");
        assert_eq!((operation_count, event_count), (0, 0));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn canonical_payload_provenance_rejects_false_or_changed_external_commands() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::raw_sql(
            r#"
            INSERT INTO public.billing_sessions (
                id, account_id, payment_method, amount_micro_usd
            ) VALUES ('billing-digest', 'deposit-consumer', 'stripe', 1000);
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES
                ('deposit-consumer', 0, 0),
                ('withdraw-consumer', 1000, 1000)
            "#,
        )
        .execute(&pool)
        .await
        .expect("payload provenance fixtures");
        let service = LedgerService::new(database.clone());
        let payload = json!({
            "data": {"object": {"amount_total": 1000}},
            "id": "evt-digest",
            "type": "checkout.session.completed"
        });
        let canonical_digest = canonical_json_digest(&payload).expect("canonical digest");
        let mut deposit = StripeDeposit {
            operation: operation("deposit:payload-digest", 184),
            external_event_id: ExternalEventId::random(),
            event_id: external("evt-digest"),
            checkout_session_id: external("cs-digest"),
            billing_session_id: external("billing-digest"),
            payload_digest: digest(185),
            payload: payload.clone(),
            currency: "usd".into(),
            amount: amount(1_000),
        };
        assert_ne!(deposit.payload_digest, canonical_digest);
        assert!(matches!(
            service.deposit(&deposit).await,
            Err(LedgerError::OperationConflict)
        ));
        assert_eq!(balance(&pool, "deposit-consumer").await, (0, 0));
        let pre_credit_counts: (i64, i64) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM rust_coord.financial_operations WHERE operation_key = $1), (SELECT COUNT(*) FROM rust_coord.external_events WHERE external_event_id = $2)",
        )
        .bind(deposit.operation.key.as_str())
        .bind(deposit.external_event_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("false digest counts");
        assert_eq!(pre_credit_counts, (0, 0));

        deposit.payload_digest = canonical_digest;
        let left_service = service.clone();
        let left_deposit = deposit.clone();
        let left = tokio::spawn(async move { left_service.deposit(&left_deposit).await });
        let right_service = service.clone();
        let right_deposit = deposit.clone();
        let right = tokio::spawn(async move { right_service.deposit(&right_deposit).await });
        let results = [
            left.await.expect("left deposit task").expect("left deposit"),
            right
                .await
                .expect("right deposit task")
                .expect("right deposit"),
        ];
        assert_eq!(
            results
                .iter()
                .filter(|result| result.disposition == MutationDisposition::Applied)
                .count(),
            1
        );
        assert_eq!(
            results
                .iter()
                .filter(|result| result.disposition == MutationDisposition::Replayed)
                .count(),
            1
        );
        assert_eq!(balance(&pool, "deposit-consumer").await, (1_000, 0));
        let stored_digest: Vec<u8> = sqlx::query_scalar(
            "SELECT payload_digest FROM rust_coord.external_events WHERE external_event_id = $1",
        )
        .bind(deposit.external_event_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("stored computed payload digest");
        assert_eq!(stored_digest, canonical_digest.as_bytes());

        let mut changed = deposit.clone();
        changed.payload = json!({
            "data": {"object": {"amount_total": 999}},
            "id": "evt-digest",
            "type": "checkout.session.completed"
        });
        changed.payload_digest =
            canonical_json_digest(&changed.payload).expect("changed canonical digest");
        assert!(matches!(
            service.deposit(&changed).await,
            Err(LedgerError::OperationConflict)
        ));
        assert_eq!(balance(&pool, "deposit-consumer").await, (1_000, 0));

        let withdrawal_payload = json!({"amount": 500, "withdrawal": "digest-withdrawal"});
        let mut withdrawal = WithdrawalRequest {
            operation: operation("withdraw:payload-digest", 186),
            outbox_id: darkbloom_coordinator_server::ledger::OutboxId::random(),
            withdrawal_id: WithdrawalId::new("digest-withdrawal").expect("withdrawal"),
            account_id: account("withdraw-consumer"),
            stripe_account_id: external("acct-digest"),
            amount: amount(500),
            fee: amount(0),
            method: "standard".into(),
            idempotency_key: "withdraw:digest:idempotency".into(),
            payload_digest: digest(187),
            external_payload: withdrawal_payload.clone(),
        };
        assert!(matches!(
            service.create_withdrawal(&withdrawal).await,
            Err(LedgerError::OperationConflict)
        ));
        assert_eq!(
            balance(&pool, "withdraw-consumer").await,
            (1_000, 1_000)
        );
        withdrawal.payload_digest =
            canonical_json_digest(&withdrawal_payload).expect("withdrawal digest");
        service
            .create_withdrawal(&withdrawal)
            .await
            .expect("valid withdrawal");
        let mut changed_withdrawal = withdrawal.clone();
        changed_withdrawal.external_payload =
            json!({"amount": 499, "withdrawal": "digest-withdrawal"});
        changed_withdrawal.payload_digest =
            canonical_json_digest(&changed_withdrawal.external_payload)
                .expect("changed withdrawal digest");
        assert!(matches!(
            service.create_withdrawal(&changed_withdrawal).await,
            Err(LedgerError::OperationConflict)
        ));
        assert_eq!(balance(&pool, "withdraw-consumer").await, (500, 500));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn reservation_shrink_avoids_safe_final_balance_intermediate_overflow() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", i64::MAX, 0).await;
        let service = LedgerService::new(database.clone());
        let reserve = reserve_request("reserve:near-max", 104, "consumer", 100);
        let reserved = service.reserve(&reserve).await.expect("reserve near max");
        assert_eq!(balance(&pool, "consumer").await, (i64::MAX - 100, 0));

        let resized = service
            .resize_and_authorize(&PreparedReservation {
                operation: operation("resize:near-max", 105),
                job_id: reserve.job_id,
                expected_version: reserved.version,
                expected_state: JobState::Reserved,
                attempt_id: AttemptId::random(),
                attempt_kind: DurableAttemptKind::Primary,
                provider_id: Uuid::new_v4(),
                provider_process_generation_id: Uuid::new_v4(),
                session_epoch: version(1),
                lease_id: Uuid::new_v4(),
                permit_id: Uuid::new_v4(),
                dispatch_nonce: digest(106),
                request_digest: digest(107),
                concrete_model: "model/build".into(),
                public_model: "model".into(),
                pricing_version: version(1),
                rounding_version: version(1),
                billable_input_tokens: 95,
                bounded_output_tokens: 0,
                input_micro_usd_per_million: amount(1_000_000),
                output_micro_usd_per_million: amount(0),
                provider_account_id: account("provider"),
                platform_account_id: account("platform"),
                referral_account_id: None,
                maximum_provider_payout: amount(95),
                maximum_platform_fee: amount(0),
                maximum_referral_reward: amount(0),
                provider_share_ppm: 1_000_000,
                referral_share_ppm: 0,
                execution_worker_id: None,
                start_deadline_millis: 15_000,
            })
            .await
            .expect("shrink reservation near max");
        assert_eq!(resized.total, amount(95));
        assert_eq!(balance(&pool, "consumer").await, (i64::MAX - 95, 0));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn owner_loss_fences_new_financial_mutations() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 100, 100).await;
        let terminated: bool = sqlx::query_scalar("SELECT pg_terminate_backend($1)")
            .bind(ownership.backend_pid())
            .fetch_one(&pool)
            .await
            .expect("terminate owner backend");
        assert!(terminated);
        tokio::time::timeout(
            Duration::from_secs(2),
            ownership.status().wait_until_unhealthy(),
        )
        .await
        .expect("ownership loss");
        let error = LedgerService::new(database.clone())
            .reserve(&reserve_request("reserve:owner-lost", 103, "consumer", 1))
            .await
            .expect_err("mutation survived owner loss");
        assert!(matches!(
            error,
            LedgerError::OwnershipLost | LedgerError::OwnershipUnavailable
        ));

        pool.close().await;
        database
            .close(Duration::from_secs(2))
            .await
            .expect("close database");
        assert!(ownership.release().await.is_err());
    })
    .await;
}

#[tokio::test]
async fn prepared_resize_and_terminal_settlement_are_atomic() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 600).await;
        let service = LedgerService::new(database.clone());
        let reserve = reserve_request("reserve:settle", 10, "consumer", 500);
        let reserved = service.reserve(&reserve).await.expect("reserve");
        assert_eq!(reserved.withdrawable, amount(100));

        let attempt_id = AttemptId::random();
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let prepared = PreparedReservation {
            operation: operation("resize:settle", 11),
            job_id: reserve.job_id,
            expected_version: reserved.version,
            expected_state: JobState::Reserved,
            attempt_id,
            attempt_kind: DurableAttemptKind::Primary,
            provider_id,
            provider_process_generation_id: generation_id,
            session_epoch: version(1),
            lease_id: Uuid::new_v4(),
            permit_id: Uuid::new_v4(),
            dispatch_nonce: digest(12),
            request_digest: digest(13),
            concrete_model: "model/build".into(),
            public_model: "model".into(),
            pricing_version: version(1),
            rounding_version: version(1),
            billable_input_tokens: 100,
            bounded_output_tokens: 100,
            input_micro_usd_per_million: amount(1_000_000),
            output_micro_usd_per_million: amount(2_000_000),
            provider_account_id: account("provider"),
            platform_account_id: account("platform"),
            referral_account_id: Some(account("referrer")),
            maximum_provider_payout: amount(225),
            maximum_platform_fee: amount(60),
            maximum_referral_reward: amount(15),
            provider_share_ppm: 750_000,
            referral_share_ppm: 200_000,
            execution_worker_id: None,
            start_deadline_millis: 15_000,
        };
        let authorized = service
            .resize_and_authorize(&prepared)
            .await
            .expect("resize and authorize");
        assert_eq!(authorized.total, amount(300));
        assert_eq!(authorized.state, JobState::StartAuthorized);
        assert!(matches!(
            service
                .record_start_dispatch(&StartDispatchRequest {
                    job_id: reserve.job_id,
                    expected_job_version: version(
                        u64::try_from(authorized.version.as_i64()).expect("positive version") + 1,
                    ),
                    expected_job_state: authorized.state,
                    attempt_id,
                    expected_attempt_version: version(1),
                    expected_attempt_state: AttemptState::NotSent,
                    disposition: StartDispatchDisposition::Queued,
                })
                .await,
            Err(LedgerError::StaleVersion)
        ));
        let unchanged_attempt: (String, i64) = sqlx::query_as(
            "SELECT state, version FROM rust_coord.inference_attempts WHERE attempt_id = $1",
        )
        .bind(attempt_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("dispatch CAS leaves attempt unchanged");
        assert_eq!(unchanged_attempt, ("not_sent".to_owned(), 1));
        let started = mark_started(
            &service,
            reserve.job_id,
            authorized.version,
            authorized.state,
            attempt_id,
        )
        .await;
        assert_eq!(started.job_state, JobState::Running);
        assert_eq!(started.attempt_state, AttemptState::Started);

        let mut settlement = SettleRequest {
            operation: operation("settle:terminal", 14),
            job_id: reserve.job_id,
            expected_job_version: started.job_version,
            expected_job_state: started.job_state,
            expected_attempt_version: started.attempt_version,
            terminal: TerminalFacts {
                terminal_id: TerminalId::random(),
                attempt_id,
                provider_id,
                provider_process_generation_id: generation_id,
                origin_session_epoch: version(1),
                terminal_digest: digest(15),
                raw_terminal: json!({"type": "terminal"}),
                outcome: TerminalOutcome::Completed,
                error_class: None,
                prompt_tokens: 100,
                completion_tokens: 50,
                reasoning_tokens: 0,
                response_digest: digest(16),
                rolling_digest: digest(17),
                final_generated_tokens: 50,
                provider_signature: vec![1, 2, 3],
                recovery_lease: None,
            },
            consumer_charge: amount(200),
            provider_payout: amount(150),
            platform_fee: amount(40),
            referral_reward: amount(10),
            accepted_cumulative_tokens: 50,
            consumer_key_hash: "consumer-key-hash".into(),
            review: None,
        };
        let mut exceeds_checkpoint = settlement.clone();
        exceeds_checkpoint.operation = operation("settle:exceeds-checkpoint", 19);
        exceeds_checkpoint.accepted_cumulative_tokens = 49;
        assert!(matches!(
            service.settle(&exceeds_checkpoint).await,
            Err(LedgerError::Invalid(_))
        ));
        let mut cancelled_settlement = settlement.clone();
        cancelled_settlement.operation = operation("settle:cancelled-terminal", 20);
        cancelled_settlement.terminal.outcome = TerminalOutcome::Cancelled;
        cancelled_settlement.terminal.error_class = Some("cancelled".into());
        assert!(matches!(
            service.settle(&cancelled_settlement).await,
            Err(LedgerError::Invalid(
                darkbloom_coordinator_server::ledger::InputError::InvalidTerminalOutcome
            ))
        ));
        assert!(matches!(
            service
                .release_terminal(&TerminalReleaseRequest {
                    operation: operation("release:completed-terminal", 21),
                    job_id: reserve.job_id,
                    expected_job_version: started.job_version,
                    expected_job_state: started.job_state,
                    expected_attempt_version: started.attempt_version,
                    terminal: settlement.terminal.clone(),
                    accepted_cumulative_tokens: 50,
                    reason: "invalid completed release".into(),
                })
                .await,
            Err(LedgerError::Invalid(
                darkbloom_coordinator_server::ledger::InputError::InvalidTerminalOutcome
            ))
        ));
        sqlx::query("DELETE FROM public.usage_totals WHERE id = 1")
            .execute(&pool)
            .await
            .expect("remove usage total atomicity prerequisite");
        let consumer_before = balance(&pool, "consumer").await;
        assert!(matches!(
            service.settle(&settlement).await,
            Err(LedgerError::OperationConflict)
        ));
        assert_eq!(balance(&pool, "consumer").await, consumer_before);
        assert_eq!(balance(&pool, "provider").await, (0, 0));
        let partial_terminals: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM rust_coord.provider_terminals")
                .fetch_one(&pool)
                .await
                .expect("partial terminal count");
        let partial_operations: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM rust_coord.financial_operations WHERE operation_key = $1",
        )
        .bind(settlement.operation.key.as_str())
        .fetch_one(&pool)
        .await
        .expect("partial operation count");
        assert_eq!((partial_terminals, partial_operations), (0, 0));
        sqlx::query("INSERT INTO public.usage_totals (id) VALUES (1)")
            .execute(&pool)
            .await
            .expect("restore usage total");
        let mut invalid_referral_split = settlement.clone();
        invalid_referral_split.operation = operation("settle:invalid-referral-split", 18);
        invalid_referral_split.platform_fee = amount(50);
        invalid_referral_split.referral_reward = amount(0);
        assert!(matches!(
            service.settle(&invalid_referral_split).await,
            Err(LedgerError::OperationConflict)
        ));
        assert_eq!(balance(&pool, "consumer").await, consumer_before);

        sqlx::query(
            "UPDATE rust_coord.inference_jobs SET accepted_cumulative_tokens = 50 WHERE job_id = $1",
        )
        .bind(reserve.job_id.as_uuid())
        .execute(&pool)
        .await
        .expect("persist accepted checkpoint for recovery settlement");
        seed_pending_terminal(&pool, reserve.job_id, &settlement.terminal).await;
        let terminal_worker = Uuid::new_v4();
        let claimed = RecoveryService::new(database.clone())
            .claim_terminals(terminal_worker, 1, Duration::from_secs(1))
            .await
            .expect("claim pending terminal");
        assert_eq!(claimed.len(), 1);
        let claimed = claimed.into_iter().next().expect("claimed terminal");
        settlement.expected_job_version = claimed.job_version;
        settlement.expected_job_state = claimed.job_state;
        settlement.expected_attempt_version = claimed.attempt_version;
        settlement.terminal = claimed.into_terminal_facts();
        let settled = service.settle(&settlement).await.expect("settle");
        assert_eq!(settled.charged, amount(200));
        assert_eq!(settled.refunded, amount(100));
        assert_eq!(balance(&pool, "consumer").await, (800, 600));
        assert_eq!(balance(&pool, "provider").await, (150, 150));
        assert_eq!(balance(&pool, "platform").await, (40, 0));
        assert_eq!(balance(&pool, "referrer").await, (10, 10));

        let replay = service.settle(&settlement).await.expect("settle replay");
        assert_eq!(replay.disposition, MutationDisposition::Replayed);
        assert_eq!(balance(&pool, "provider").await, (150, 150));

        let terminal_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM rust_coord.provider_terminals")
                .fetch_one(&pool)
                .await
                .expect("terminal count");
        let usage_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM public.usage")
            .fetch_one(&pool)
            .await
            .expect("usage count");
        assert_eq!((terminal_count, usage_count), (1, 1));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn hard_untrust_epoch_atomically_fences_resize_settle_and_terminal_release() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 2_000, 2_000).await;
        let service = LedgerService::new(database.clone());

        let resize_reserve = reserve_request("reserve:untrusted-resize", 130, "consumer", 500);
        let resize_reserved = service
            .reserve(&resize_reserve)
            .await
            .expect("reserve resize job");
        let resize_provider = Uuid::new_v4();
        seed_hard_untrust(&pool, resize_provider, version(1), digest(131)).await;
        let resize_prepared = standard_prepared(
            "resize:hard-untrusted",
            132,
            resize_reserve.job_id,
            resize_reserved.version,
            AttemptId::random(),
            resize_provider,
            Uuid::new_v4(),
        );
        assert!(matches!(
            service.resize_and_authorize(&resize_prepared).await,
            Err(LedgerError::ProviderHardUntrusted)
        ));
        let resize_state: String =
            sqlx::query_scalar("SELECT state FROM rust_coord.inference_jobs WHERE job_id = $1")
                .bind(resize_reserve.job_id.as_uuid())
                .fetch_one(&pool)
                .await
                .expect("resize job state");
        assert_eq!(resize_state, "reserved");

        let terminal_reserve = reserve_request("reserve:untrusted-terminal", 133, "consumer", 500);
        let terminal_reserved = service
            .reserve(&terminal_reserve)
            .await
            .expect("reserve terminal job");
        let terminal_provider = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let attempt_id = AttemptId::random();
        let terminal_prepared = standard_prepared(
            "resize:terminal-before-untrust",
            134,
            terminal_reserve.job_id,
            terminal_reserved.version,
            attempt_id,
            terminal_provider,
            generation_id,
        );
        let authorized = service
            .resize_and_authorize(&terminal_prepared)
            .await
            .expect("authorize terminal job");
        let started = mark_started(
            &service,
            terminal_reserve.job_id,
            authorized.version,
            authorized.state,
            attempt_id,
        )
        .await;
        seed_hard_untrust(&pool, terminal_provider, version(1), digest(135)).await;

        let terminal = TerminalFacts {
            terminal_id: TerminalId::random(),
            attempt_id,
            provider_id: terminal_provider,
            provider_process_generation_id: generation_id,
            origin_session_epoch: version(1),
            terminal_digest: digest(136),
            raw_terminal: json!({"type": "terminal"}),
            outcome: TerminalOutcome::Completed,
            error_class: None,
            prompt_tokens: 100,
            completion_tokens: 0,
            reasoning_tokens: 0,
            response_digest: digest(137),
            rolling_digest: digest(138),
            final_generated_tokens: 0,
            provider_signature: vec![1],
            recovery_lease: None,
        };
        let balance_before = balance(&pool, "consumer").await;
        assert!(matches!(
            service
                .settle(&SettleRequest {
                    operation: operation("settle:hard-untrusted", 139),
                    job_id: terminal_reserve.job_id,
                    expected_job_version: started.job_version,
                    expected_job_state: started.job_state,
                    expected_attempt_version: started.attempt_version,
                    terminal: terminal.clone(),
                    consumer_charge: amount(100),
                    provider_payout: amount(75),
                    platform_fee: amount(20),
                    referral_reward: amount(5),
                    accepted_cumulative_tokens: 0,
                    consumer_key_hash: "consumer-key-hash".into(),
                    review: None,
                })
                .await,
            Err(LedgerError::ProviderHardUntrusted)
        ));

        let mut released_terminal = terminal;
        released_terminal.terminal_id = TerminalId::random();
        released_terminal.terminal_digest = digest(140);
        released_terminal.outcome = TerminalOutcome::Cancelled;
        released_terminal.error_class = Some("cancelled".into());
        assert!(matches!(
            service
                .release_terminal(&TerminalReleaseRequest {
                    operation: operation("terminal-release:hard-untrusted", 141),
                    job_id: terminal_reserve.job_id,
                    expected_job_version: started.job_version,
                    expected_job_state: started.job_state,
                    expected_attempt_version: started.attempt_version,
                    terminal: released_terminal,
                    accepted_cumulative_tokens: 0,
                    reason: "provider cancellation".into(),
                })
                .await,
            Err(LedgerError::ProviderHardUntrusted)
        ));
        assert_eq!(balance(&pool, "consumer").await, balance_before);
        let terminal_rows: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM rust_coord.provider_terminals WHERE job_id = $1",
        )
        .bind(terminal_reserve.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("terminal row count");
        assert_eq!(terminal_rows, 0);

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn explicit_review_settlement_is_audited_and_replay_safe() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 1_000).await;
        let service = LedgerService::new(database.clone());
        let reserve = reserve_request("reserve:review-settle", 142, "consumer", 300);
        let reserved = service.reserve(&reserve).await.expect("reserve review job");
        let attempt_id = AttemptId::random();
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let prepared = standard_prepared(
            "resize:review-settle",
            143,
            reserve.job_id,
            reserved.version,
            attempt_id,
            provider_id,
            generation_id,
        );
        let authorized = service
            .resize_and_authorize(&prepared)
            .await
            .expect("authorize review job");
        mark_started(
            &service,
            reserve.job_id,
            authorized.version,
            authorized.state,
            attempt_id,
        )
        .await;
        let terminal = TerminalFacts {
            terminal_id: TerminalId::random(),
            attempt_id,
            provider_id,
            provider_process_generation_id: generation_id,
            origin_session_epoch: version(1),
            terminal_digest: digest(144),
            raw_terminal: json!({"type": "terminal", "review": "settle"}),
            outcome: TerminalOutcome::Completed,
            error_class: None,
            prompt_tokens: 100,
            completion_tokens: 0,
            reasoning_tokens: 0,
            response_digest: digest(145),
            rolling_digest: digest(146),
            final_generated_tokens: 0,
            provider_signature: vec![1],
            recovery_lease: None,
        };
        service
            .record_terminal_conflict(
                reserve.job_id,
                attempt_id,
                &terminal,
                "operator_review_required",
                0,
            )
            .await
            .expect("quarantine terminal");
        assert!(matches!(
            service
                .ensure_provider_trusted(provider_id, version(1))
                .await,
            Err(LedgerError::ProviderHardUntrusted)
        ));

        let command = OperatorCommand::parse([
            OsString::from("review-resolve"),
            OsString::from("--job"),
            OsString::from(reserve.job_id.to_string()),
            OsString::from("--disposition"),
            OsString::from("settle"),
            OsString::from("--reason"),
            OsString::from("signed evidence accepted after operator investigation"),
        ])
        .expect("parse settle review command");
        let applied = command
            .execute_one_shot(database.clone())
            .await
            .expect("settle reviewed job");
        assert_eq!(applied["disposition"], "applied");
        assert_eq!(applied["state"], "settled_reviewed");
        let replay = command
            .execute_one_shot(database.clone())
            .await
            .expect("replay settle review command");
        assert_eq!(replay["disposition"], "replayed");
        assert_eq!(balance(&pool, "consumer").await, (900, 900));
        assert_eq!(balance(&pool, "provider").await, (75, 75));
        assert_eq!(balance(&pool, "platform").await, (20, 0));
        assert_eq!(balance(&pool, "referrer").await, (5, 5));
        assert_eq!(
            service
                .lookup_terminal(
                    DurableAttemptIdentity {
                        request_id: reserve.request_id,
                        reservation_id: reserve.reservation_id,
                        attempt_id,
                        provider_id,
                        provider_process_generation_id: generation_id,
                        session_epoch: version(1),
                        lease_id: prepared.lease_id,
                    },
                    terminal.terminal_digest,
                )
                .await
                .expect("review settlement lookup"),
            TerminalLookup::Known(DurableTerminalDisposition::SettledReviewed)
        );

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn signed_cancellation_terminal_releases_once_and_refunds_exact_provenance() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 600).await;
        let service = LedgerService::new(database.clone());
        let reserve = reserve_request("reserve:cancelled-terminal", 147, "consumer", 500);
        let reserved = service.reserve(&reserve).await.expect("reserve");
        let attempt_id = AttemptId::random();
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let authorized = service
            .resize_and_authorize(&standard_prepared(
                "resize:cancelled-terminal",
                148,
                reserve.job_id,
                reserved.version,
                attempt_id,
                provider_id,
                generation_id,
            ))
            .await
            .expect("authorize");
        let started = mark_started(
            &service,
            reserve.job_id,
            authorized.version,
            authorized.state,
            attempt_id,
        )
        .await;
        let request = TerminalReleaseRequest {
            operation: operation("release:cancelled-terminal", 149),
            job_id: reserve.job_id,
            expected_job_version: started.job_version,
            expected_job_state: started.job_state,
            expected_attempt_version: started.attempt_version,
            terminal: TerminalFacts {
                terminal_id: TerminalId::random(),
                attempt_id,
                provider_id,
                provider_process_generation_id: generation_id,
                origin_session_epoch: version(1),
                terminal_digest: digest(150),
                raw_terminal: json!({"type": "terminal", "outcome": "cancelled"}),
                outcome: TerminalOutcome::Cancelled,
                error_class: Some("cancelled".into()),
                prompt_tokens: 100,
                completion_tokens: 10,
                reasoning_tokens: 0,
                response_digest: digest(151),
                rolling_digest: digest(152),
                final_generated_tokens: 10,
                provider_signature: vec![1],
                recovery_lease: None,
            },
            accepted_cumulative_tokens: 0,
            reason: "provider cancellation".into(),
        };
        let released = service
            .release_terminal(&request)
            .await
            .expect("terminal release");
        assert_eq!(released.disposition, MutationDisposition::Applied);
        assert_eq!(released.state, JobState::Released);
        assert_eq!(released.total, amount(300));
        assert_eq!(released.withdrawable, amount(0));
        assert_eq!(balance(&pool, "consumer").await, (1_000, 600));
        let replay = service
            .release_terminal(&request)
            .await
            .expect("terminal release replay");
        assert_eq!(replay.disposition, MutationDisposition::Replayed);
        assert_eq!(balance(&pool, "consumer").await, (1_000, 600));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn signed_precontent_failure_keeps_reservation_and_authorizes_one_alternate() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 600).await;
        let service = LedgerService::new(database.clone());
        let reserve = reserve_request("reserve:precontent-retry", 153, "consumer", 500);
        let reserved = service.reserve(&reserve).await.expect("reserve");
        let primary_attempt_id = AttemptId::random();
        let primary_provider_id = Uuid::new_v4();
        let primary_generation_id = Uuid::new_v4();
        let primary = standard_prepared(
            "resize:precontent-primary",
            154,
            reserve.job_id,
            reserved.version,
            primary_attempt_id,
            primary_provider_id,
            primary_generation_id,
        );
        let authorized = service
            .resize_and_authorize(&primary)
            .await
            .expect("authorize primary");
        let started = mark_started(
            &service,
            reserve.job_id,
            authorized.version,
            authorized.state,
            primary_attempt_id,
        )
        .await;
        let release = TerminalReleaseRequest {
            operation: operation("release:precontent-primary", 155),
            job_id: reserve.job_id,
            expected_job_version: started.job_version,
            expected_job_state: started.job_state,
            expected_attempt_version: started.attempt_version,
            terminal: TerminalFacts {
                terminal_id: TerminalId::random(),
                attempt_id: primary_attempt_id,
                provider_id: primary_provider_id,
                provider_process_generation_id: primary_generation_id,
                origin_session_epoch: version(1),
                terminal_digest: digest(156),
                raw_terminal: json!({"type": "terminal", "outcome": "error"}),
                outcome: TerminalOutcome::Error,
                error_class: Some("fault".into()),
                prompt_tokens: 100,
                completion_tokens: 5,
                reasoning_tokens: 0,
                response_digest: digest(157),
                rolling_digest: digest(158),
                final_generated_tokens: 5,
                provider_signature: vec![1],
                recovery_lease: None,
            },
            accepted_cumulative_tokens: 5,
            reason: "provider failed after metadata only".into(),
        };

        let retried = service
            .retry_precontent(&release)
            .await
            .expect("release precontent primary");
        assert_eq!(retried.disposition, MutationDisposition::Applied);
        assert_eq!(retried.state, JobState::Prepared);
        assert_eq!(retried.total, amount(300));
        assert_eq!(balance(&pool, "consumer").await, (700, 600));
        let primary_state: String = sqlx::query_scalar(
            "SELECT state FROM rust_coord.inference_attempts WHERE attempt_id = $1",
        )
        .bind(primary_attempt_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("primary attempt state");
        assert_eq!(primary_state, "aborted");
        let refunds: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM public.ledger_entries WHERE reference = $1")
                .bind(format!(
                    "rust-terminal-release:{}",
                    release.operation.key.as_str()
                ))
                .fetch_one(&pool)
                .await
                .expect("precontent refund count");
        assert_eq!(refunds, 0);

        let replay = service
            .retry_precontent(&release)
            .await
            .expect("precontent retry replay");
        assert_eq!(replay.disposition, MutationDisposition::Replayed);
        assert_eq!(balance(&pool, "consumer").await, (700, 600));

        let alternate_attempt_id = AttemptId::random();
        let mut alternate = standard_prepared(
            "resize:precontent-alternate",
            159,
            reserve.job_id,
            retried.version,
            alternate_attempt_id,
            Uuid::new_v4(),
            Uuid::new_v4(),
        );
        alternate.expected_state = JobState::Prepared;
        alternate.attempt_kind = DurableAttemptKind::Alternate;
        let alternate_authorized = service
            .resize_and_authorize(&alternate)
            .await
            .expect("authorize alternate");
        assert_eq!(alternate_authorized.state, JobState::StartAuthorized);
        assert_eq!(balance(&pool, "consumer").await, (700, 600));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn conflicting_terminal_is_quarantined_and_review_release_is_once_only() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 1_000).await;
        let service = LedgerService::new(database.clone());
        let reserve = reserve_request("reserve:review", 120, "consumer", 300);
        let reserved = service.reserve(&reserve).await.expect("reserve review job");
        let attempt_id = AttemptId::random();
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let lease_id = Uuid::new_v4();
        let authorized = service
            .resize_and_authorize(&PreparedReservation {
                operation: operation("resize:review", 121),
                job_id: reserve.job_id,
                expected_version: reserved.version,
                expected_state: reserved.state,
                attempt_id,
                attempt_kind: DurableAttemptKind::Primary,
                provider_id,
                provider_process_generation_id: generation_id,
                session_epoch: version(1),
                lease_id,
                permit_id: Uuid::new_v4(),
                dispatch_nonce: digest(122),
                request_digest: digest(123),
                concrete_model: "model/build".into(),
                public_model: "model".into(),
                pricing_version: version(1),
                rounding_version: version(1),
                billable_input_tokens: 100,
                bounded_output_tokens: 100,
                input_micro_usd_per_million: amount(1_000_000),
                output_micro_usd_per_million: amount(2_000_000),
                provider_account_id: account("provider"),
                platform_account_id: account("platform"),
                referral_account_id: Some(account("referrer")),
                maximum_provider_payout: amount(225),
                maximum_platform_fee: amount(60),
                maximum_referral_reward: amount(15),
                provider_share_ppm: 750_000,
                referral_share_ppm: 200_000,
                execution_worker_id: None,
                start_deadline_millis: 15_000,
            })
            .await
            .expect("authorize review job");
        mark_started(
            &service,
            reserve.job_id,
            authorized.version,
            authorized.state,
            attempt_id,
        )
        .await;

        let first = TerminalFacts {
            terminal_id: TerminalId::random(),
            attempt_id,
            provider_id,
            provider_process_generation_id: generation_id,
            origin_session_epoch: version(1),
            terminal_digest: digest(124),
            raw_terminal: json!({"type": "terminal", "marker": 1}),
            outcome: TerminalOutcome::Completed,
            error_class: None,
            prompt_tokens: 100,
            completion_tokens: 0,
            reasoning_tokens: 0,
            response_digest: digest(125),
            rolling_digest: digest(126),
            final_generated_tokens: 0,
            provider_signature: vec![1],
            recovery_lease: None,
        };
        assert!(matches!(
            service
                .record_terminal_for_recovery(&first)
                .await
                .expect("record first terminal"),
            darkbloom_coordinator_server::ledger::RecoveryTerminalRecordResult::Pending {
                job_id
            } if job_id == reserve.job_id
        ));
        let mut conflict = first.clone();
        conflict.terminal_id = TerminalId::random();
        conflict.terminal_digest = digest(127);
        conflict.raw_terminal = json!({"type": "terminal", "marker": 2});
        conflict.completion_tokens = 50;
        conflict.final_generated_tokens = 50;
        assert!(matches!(
            service
                .record_terminal_for_recovery(&conflict)
                .await
                .expect("record conflicting terminal"),
            darkbloom_coordinator_server::ledger::RecoveryTerminalRecordResult::Conflict {
                job_id
            } if job_id == reserve.job_id
        ));
        assert!(matches!(
            service.ensure_provider_trusted(provider_id, version(1)).await,
            Err(LedgerError::ProviderHardUntrusted)
        ));
        let mut rejected_reserve =
            reserve_request("reserve:hard-untrusted", 128, "consumer", 100);
        rejected_reserve.provisional_provider_id = Some(provider_id);
        rejected_reserve.provisional_session_epoch = Some(version(1));
        assert!(matches!(
            service.reserve(&rejected_reserve).await,
            Err(LedgerError::ProviderHardUntrusted)
        ));
        let accepted: i64 = sqlx::query_scalar(
            "SELECT accepted_cumulative_tokens FROM rust_coord.inference_jobs WHERE job_id = $1",
        )
        .bind(reserve.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("accepted checkpoint");
        assert_eq!(accepted, 0, "provider terminal cannot inflate accepted output");
        assert_eq!(balance(&pool, "consumer").await, (700, 700));

        let command = OperatorCommand::parse([
            OsString::from("review-resolve"),
            OsString::from("--job"),
            OsString::from(reserve.job_id.to_string()),
            OsString::from("--disposition"),
            OsString::from("release"),
            OsString::from("--reason"),
            OsString::from("conflicting signed terminal evidence"),
        ])
        .expect("parse review command");
        let (left, right) = tokio::join!(
            command.execute_one_shot(database.clone()),
            command.execute_one_shot(database.clone())
        );
        let mut dispositions = [left, right]
            .into_iter()
            .map(|result| {
                result
                    .expect("concurrent review resolution")
                    .get("disposition")
                    .and_then(serde_json::Value::as_str)
                    .expect("review disposition")
                    .to_owned()
            })
            .collect::<Vec<_>>();
        dispositions.sort();
        assert_eq!(dispositions, ["applied", "replayed"]);
        assert_eq!(balance(&pool, "consumer").await, (1_000, 1_000));
        let journal: (i64, String) = sqlx::query_as(
            "SELECT COUNT(*), MIN(operator_reason) FROM rust_coord.review_resolution_journal WHERE job_id = $1",
        )
        .bind(reserve.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("review journal");
        assert_eq!(
            journal,
            (1, "conflicting signed terminal evidence".to_owned())
        );
        let dispositions: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM rust_coord.financial_operations WHERE job_id = $1 AND kind IN ('settle', 'release')",
        )
        .bind(reserve.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("review money dispositions");
        assert_eq!(dispositions, 1);
        assert_eq!(
            service
                .lookup_terminal(
                    DurableAttemptIdentity {
                        request_id: reserve.request_id,
                        reservation_id: reserve.reservation_id,
                        attempt_id,
                        provider_id,
                        provider_process_generation_id: generation_id,
                        session_epoch: version(1),
                        lease_id,
                    },
                    conflict.terminal_digest,
                )
                .await
                .expect("reviewed conflict lookup"),
            TerminalLookup::Known(DurableTerminalDisposition::ReleasedReviewed)
        );
        assert_eq!(
            service
                .lookup_terminal(
                    DurableAttemptIdentity {
                        request_id: reserve.request_id,
                        reservation_id: reserve.reservation_id,
                        attempt_id,
                        provider_id,
                        provider_process_generation_id: generation_id,
                        session_epoch: version(1),
                        lease_id: Uuid::new_v4(),
                    },
                    conflict.terminal_digest,
                )
                .await
                .expect("foreign lease lookup"),
            TerminalLookup::Conflict {
                job_id: reserve.job_id
            }
        );
        let mut third = conflict.clone();
        third.terminal_id = TerminalId::random();
        third.terminal_digest = digest(129);
        third.raw_terminal = json!({"type": "terminal", "marker": 3});
        assert_eq!(
            service
                .lookup_terminal(
                    DurableAttemptIdentity {
                        request_id: reserve.request_id,
                        reservation_id: reserve.reservation_id,
                        attempt_id,
                        provider_id,
                        provider_process_generation_id: generation_id,
                        session_epoch: version(1),
                        lease_id,
                    },
                    third.terminal_digest,
                )
                .await
                .expect("third digest lookup"),
            TerminalLookup::Conflict {
                job_id: reserve.job_id
            }
        );
        service
            .record_terminal_conflict(
                reserve.job_id,
                attempt_id,
                &third,
                "terminal_digest_conflict",
                0,
            )
            .await
            .expect("persist third digest conflict");
        let third_conflict: (bool, String) = sqlx::query_as(
            "SELECT conflict, status FROM rust_coord.provider_terminals WHERE terminal_digest = $1",
        )
        .bind(third.terminal_digest.as_bytes().as_slice())
        .fetch_one(&pool)
        .await
        .expect("third conflict evidence");
        assert_eq!(third_conflict, (true, "conflict".to_owned()));
        let job_state: String =
            sqlx::query_scalar("SELECT state FROM rust_coord.inference_jobs WHERE job_id = $1")
                .bind(reserve.job_id.as_uuid())
                .fetch_one(&pool)
                .await
                .expect("reviewed job state");
        assert_eq!(job_state, "released_reviewed");
        let dispositions_after_conflict: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM rust_coord.financial_operations WHERE job_id = $1 AND kind IN ('settle', 'release')",
        )
        .bind(reserve.job_id.as_uuid())
        .fetch_one(&pool)
        .await
        .expect("money dispositions after third digest");
        assert_eq!(dispositions_after_conflict, 1);

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn deterministic_account_order_survives_cross_account_settlement_stress() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "account-a", 100_000, 100_000).await;
        seed_balance(&pool, "account-b", 100_000, 100_000).await;
        let service = LedgerService::new(database.clone());
        let mut settlements = Vec::new();
        for index in 0_u64..20 {
            let consumer = if index % 2 == 0 {
                "account-a"
            } else {
                "account-b"
            };
            let provider = if index % 2 == 0 {
                "account-b"
            } else {
                "account-a"
            };
            let reserve = ReserveRequest {
                operation: Operation::new(
                    OperationKey::new(format!("stress:reserve:{index}")).expect("key"),
                    digest_number(1_000 + index * 3),
                ),
                job_id: JobId::random(),
                request_id: Uuid::new_v4(),
                reservation_id: ReservationId::random(),
                account_id: account(consumer),
                api_key_id: Arc::from("stress-key"),
                consumer_key_hash: Arc::from("stress-key-hash"),
                amount: amount(200),
                request_deadline_epoch_millis: TEST_REQUEST_DEADLINE_EPOCH_MILLIS,
                execution_worker_id: None,
                execution_lease_millis: None,
                provisional_provider_id: None,
                provisional_session_epoch: None,
                public_model: Arc::from(""),
                concrete_model: Arc::from(""),
                api_key_limit_micro_usd: None,
                api_key_controlled: false,
            };
            let reserved = service.reserve(&reserve).await.expect("stress reserve");
            let attempt_id = AttemptId::random();
            let provider_id = Uuid::new_v4();
            let generation_id = Uuid::new_v4();
            let authorized = service
                .resize_and_authorize(&PreparedReservation {
                    operation: Operation::new(
                        OperationKey::new(format!("stress:resize:{index}")).expect("key"),
                        digest_number(1_001 + index * 3),
                    ),
                    job_id: reserve.job_id,
                    expected_version: reserved.version,
                    expected_state: JobState::Reserved,
                    attempt_id,
                    attempt_kind: DurableAttemptKind::Primary,
                    provider_id,
                    provider_process_generation_id: generation_id,
                    session_epoch: version(1),
                    lease_id: Uuid::new_v4(),
                    permit_id: Uuid::new_v4(),
                    dispatch_nonce: digest_number(2_000 + index),
                    request_digest: digest_number(3_000 + index),
                    concrete_model: "stress/model".into(),
                    public_model: "stress".into(),
                    pricing_version: version(1),
                    rounding_version: version(1),
                    billable_input_tokens: 100,
                    bounded_output_tokens: 100,
                    input_micro_usd_per_million: amount(1_000_000),
                    output_micro_usd_per_million: amount(1_000_000),
                    provider_account_id: account(provider),
                    platform_account_id: account("platform"),
                    referral_account_id: None,
                    maximum_provider_payout: amount(200),
                    maximum_platform_fee: amount(0),
                    maximum_referral_reward: amount(0),
                    provider_share_ppm: 1_000_000,
                    referral_share_ppm: 0,
                    execution_worker_id: None,
                    start_deadline_millis: 15_000,
                })
                .await
                .expect("stress authorize");
            let started = mark_started(
                &service,
                reserve.job_id,
                authorized.version,
                authorized.state,
                attempt_id,
            )
            .await;
            settlements.push(SettleRequest {
                operation: Operation::new(
                    OperationKey::new(format!("stress:settle:{index}")).expect("key"),
                    digest_number(1_002 + index * 3),
                ),
                job_id: reserve.job_id,
                expected_job_version: started.job_version,
                expected_job_state: started.job_state,
                expected_attempt_version: started.attempt_version,
                terminal: TerminalFacts {
                    terminal_id: TerminalId::random(),
                    attempt_id,
                    provider_id,
                    provider_process_generation_id: generation_id,
                    origin_session_epoch: version(1),
                    terminal_digest: digest_number(4_000 + index),
                    raw_terminal: json!({"index": index}),
                    outcome: TerminalOutcome::Completed,
                    error_class: None,
                    prompt_tokens: 100,
                    completion_tokens: 50,
                    reasoning_tokens: 0,
                    response_digest: digest_number(5_000 + index),
                    rolling_digest: digest_number(6_000 + index),
                    final_generated_tokens: 50,
                    provider_signature: vec![1],
                    recovery_lease: None,
                },
                consumer_charge: amount(150),
                provider_payout: amount(150),
                platform_fee: amount(0),
                referral_reward: amount(0),
                accepted_cumulative_tokens: 50,
                consumer_key_hash: "stress-key-hash".into(),
                review: None,
            });
        }

        tokio::time::timeout(Duration::from_secs(15), async {
            let tasks: Vec<_> = settlements
                .into_iter()
                .map(|settlement| {
                    let service = service.clone();
                    tokio::spawn(async move { service.settle(&settlement).await })
                })
                .collect();
            for task in tasks {
                task.await
                    .expect("settlement task")
                    .expect("cross-account settlement");
            }
        })
        .await
        .expect("settlement stress deadlocked");
        assert_eq!(balance(&pool, "account-a").await, (100_000, 100_000));
        assert_eq!(balance(&pool, "account-b").await, (100_000, 100_000));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn stale_terminal_rolls_back_every_side_effect() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 1_000).await;
        let service = LedgerService::new(database.clone());
        let reserve = reserve_request("reserve:rollback", 20, "consumer", 300);
        let reserved = service.reserve(&reserve).await.expect("reserve");
        let attempt_id = AttemptId::random();
        let provider_id = Uuid::new_v4();
        let generation_id = Uuid::new_v4();
        let authorized = service
            .resize_and_authorize(&PreparedReservation {
                operation: operation("resize:rollback", 21),
                job_id: reserve.job_id,
                expected_version: reserved.version,
                expected_state: JobState::Reserved,
                attempt_id,
                attempt_kind: DurableAttemptKind::Primary,
                provider_id,
                provider_process_generation_id: generation_id,
                session_epoch: version(1),
                lease_id: Uuid::new_v4(),
                permit_id: Uuid::new_v4(),
                dispatch_nonce: digest(22),
                request_digest: digest(23),
                concrete_model: "model/build".into(),
                public_model: "model".into(),
                pricing_version: version(1),
                rounding_version: version(1),
                billable_input_tokens: 100,
                bounded_output_tokens: 100,
                input_micro_usd_per_million: amount(1_000_000),
                output_micro_usd_per_million: amount(2_000_000),
                provider_account_id: account("provider"),
                platform_account_id: account("platform"),
                referral_account_id: None,
                maximum_provider_payout: amount(250),
                maximum_platform_fee: amount(50),
                maximum_referral_reward: amount(0),
                provider_share_ppm: 833_334,
                referral_share_ppm: 0,
                execution_worker_id: None,
                start_deadline_millis: 15_000,
            })
            .await
            .expect("authorize");
        let before = balance(&pool, "consumer").await;
        let stale = SettleRequest {
            operation: operation("settle:stale", 24),
            job_id: reserve.job_id,
            expected_job_version: version(authorized.version.as_i64() as u64 + 1),
            expected_job_state: JobState::StartAuthorized,
            expected_attempt_version: version(1),
            terminal: TerminalFacts {
                terminal_id: TerminalId::random(),
                attempt_id,
                provider_id,
                provider_process_generation_id: generation_id,
                origin_session_epoch: version(1),
                terminal_digest: digest(25),
                raw_terminal: json!({}),
                outcome: TerminalOutcome::Completed,
                error_class: None,
                prompt_tokens: 100,
                completion_tokens: 50,
                reasoning_tokens: 0,
                response_digest: digest(26),
                rolling_digest: digest(27),
                final_generated_tokens: 50,
                provider_signature: vec![1],
                recovery_lease: None,
            },
            consumer_charge: amount(200),
            provider_payout: amount(170),
            platform_fee: amount(30),
            referral_reward: amount(0),
            accepted_cumulative_tokens: 50,
            consumer_key_hash: "consumer-key-hash".into(),
            review: None,
        };
        assert!(matches!(
            service.settle(&stale).await,
            Err(LedgerError::StaleVersion)
        ));
        assert_eq!(balance(&pool, "consumer").await, before);
        let terminals: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM rust_coord.provider_terminals")
                .fetch_one(&pool)
                .await
                .expect("terminals");
        assert_eq!(terminals, 0);

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn stripe_deposit_and_withdrawal_reversal_race_are_exactly_once() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::raw_sql(
            r#"
            INSERT INTO public.billing_sessions (
                id, account_id, payment_method, amount_micro_usd
            ) VALUES ('billing-1', 'consumer', 'stripe', 1000);
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES ('consumer', 0, 0)
            "#,
        )
        .execute(&pool)
        .await
        .expect("billing session");
        let service = LedgerService::new(database.clone());
        let deposit = StripeDeposit {
            operation: operation("deposit:evt-1", 30),
            external_event_id: ExternalEventId::random(),
            event_id: external("evt-1"),
            checkout_session_id: external("cs-1"),
            billing_session_id: external("billing-1"),
            payload_digest: canonical_json_digest(&json!({"id": "evt-1"}))
                .expect("payload digest"),
            payload: json!({"id": "evt-1"}),
            currency: "usd".into(),
            amount: amount(1_000),
        };
        assert_eq!(
            service
                .deposit(&deposit)
                .await
                .expect("deposit")
                .disposition,
            MutationDisposition::Applied
        );
        assert_eq!(
            service
                .deposit(&deposit)
                .await
                .expect("deposit replay")
                .disposition,
            MutationDisposition::Replayed
        );
        sqlx::query(
            "UPDATE public.balances SET withdrawable_micro_usd = balance_micro_usd WHERE account_id = 'consumer'",
        )
        .execute(&pool)
        .await
        .expect("make deposited test balance withdrawable");

        let withdrawal_id = WithdrawalId::new("withdraw-1").expect("withdrawal");
        service
            .create_withdrawal(&WithdrawalRequest {
                operation: operation("withdraw:create", 32),
                outbox_id: darkbloom_coordinator_server::ledger::OutboxId::random(),
                withdrawal_id: withdrawal_id.clone(),
                account_id: account("consumer"),
                stripe_account_id: external("acct-stripe"),
                amount: amount(600),
                fee: amount(100),
                method: "instant".into(),
                idempotency_key: "withdraw:race:idempotency".into(),
                payload_digest: canonical_json_digest(&json!({"withdrawal": "withdraw-1"}))
                    .expect("payload digest"),
                external_payload: json!({"withdrawal": "withdraw-1"}),
            })
            .await
            .expect("create withdrawal");

        let paid_service = service.clone();
        let paid_id = withdrawal_id.clone();
        let paid = tokio::spawn(async move {
            paid_service
                .mark_withdrawal(
                    &WithdrawalTransition {
                        operation: operation("withdraw:paid", 33),
                        withdrawal_id: paid_id,
                        expected_status: WithdrawalStatus::Pending,
                        transfer_id: None,
                        payout_id: Some(external("po-race")),
                        sweep_payout_id: None,
                        failure_reason: None,
                    },
                    WithdrawalStatus::Paid,
                )
                .await
        });
        let reversed_service = service.clone();
        let reversed = tokio::spawn(async move {
            reversed_service
                .reverse_withdrawal(&WithdrawalTransition {
                    operation: operation("withdraw:reverse", 34),
                    withdrawal_id,
                    expected_status: WithdrawalStatus::Pending,
                    transfer_id: None,
                    payout_id: None,
                    sweep_payout_id: None,
                    failure_reason: None,
                })
                .await
        });
        let (paid, reversed) = tokio::join!(paid, reversed);
        let outcomes = [paid.expect("paid task"), reversed.expect("reverse task")];
        assert_eq!(outcomes.iter().filter(|result| result.is_ok()).count(), 1);
        let (status, refunded): (String, bool) = sqlx::query_as(
            "SELECT status, refunded FROM public.stripe_withdrawals WHERE id = 'withdraw-1'",
        )
        .fetch_one(&pool)
        .await
        .expect("withdrawal state");
        match status.as_str() {
            "paid" => {
                assert!(!refunded);
                assert_eq!(balance(&pool, "consumer").await, (400, 400));
            }
            "failed" => {
                assert!(refunded);
                assert_eq!(balance(&pool, "consumer").await, (1_000, 1_000));
                assert!(outcomes.iter().any(|outcome| {
                    outcome.as_ref().is_ok_and(|result| {
                        result.disposition == WithdrawalDisposition::Applied && result.refunded
                    })
                }));
                let failure: (String, String, i64, i64) = sqlx::query_as(
                    r#"
                    SELECT idempotency_key, account_id, amount_micro_usd, fee_micro_usd
                    FROM public.stripe_withdrawal_failures
                    WHERE withdrawal_id = 'withdraw-1'
                    "#,
                )
                .fetch_one(&pool)
                .await
                .expect("withdrawal failure tombstone");
                assert_eq!(
                    failure,
                    (
                        "withdraw:race:idempotency".to_owned(),
                        "consumer".to_owned(),
                        600,
                        100,
                    )
                );
            }
            other => panic!("unexpected withdrawal status {other}"),
        }

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn failed_sweep_cannot_be_reapplied_and_withdrawal_debit_is_guarded() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 1_000, 1_000).await;
        let service = LedgerService::new(database.clone());
        let withdrawal_id = WithdrawalId::new("withdraw-sweep").expect("withdrawal");
        service
            .create_withdrawal(&WithdrawalRequest {
                operation: operation("withdraw:sweep:create", 110),
                outbox_id: darkbloom_coordinator_server::ledger::OutboxId::random(),
                withdrawal_id: withdrawal_id.clone(),
                account_id: account("consumer"),
                stripe_account_id: external("acct-sweep"),
                amount: amount(600),
                fee: amount(0),
                method: "standard".into(),
                idempotency_key: "withdraw:sweep:idempotency".into(),
                payload_digest: canonical_json_digest(&json!({"withdrawal": "withdraw-sweep"}))
                    .expect("payload digest"),
                external_payload: json!({"withdrawal": "withdraw-sweep"}),
            })
            .await
            .expect("create sweep withdrawal");
        assert!(matches!(
            service
                .create_withdrawal(&WithdrawalRequest {
                    operation: operation("withdraw:sweep:insufficient", 111),
                    outbox_id: darkbloom_coordinator_server::ledger::OutboxId::random(),
                    withdrawal_id: WithdrawalId::new("withdraw-too-large").expect("withdrawal"),
                    account_id: account("consumer"),
                    stripe_account_id: external("acct-sweep"),
                    amount: amount(500),
                    fee: amount(0),
                    method: "standard".into(),
                    idempotency_key: "withdraw:too-large:idempotency".into(),
                    payload_digest: canonical_json_digest(
                        &json!({"withdrawal": "withdraw-too-large"}),
                    )
                    .expect("payload digest"),
                    external_payload: json!({"withdrawal": "withdraw-too-large"}),
                })
                .await,
            Err(LedgerError::InsufficientBalance)
        ));

        service
            .mark_withdrawal(
                &WithdrawalTransition {
                    operation: operation("withdraw:sweep:transferred", 112),
                    withdrawal_id: withdrawal_id.clone(),
                    expected_status: WithdrawalStatus::Pending,
                    transfer_id: Some(external("tr-sweep")),
                    payout_id: None,
                    sweep_payout_id: None,
                    failure_reason: None,
                },
                WithdrawalStatus::Transferred,
            )
            .await
            .expect("mark transferred");
        service
            .mark_sweep_paid(&WithdrawalTransition {
                operation: operation("withdraw:sweep:paid-1", 113),
                withdrawal_id: withdrawal_id.clone(),
                expected_status: WithdrawalStatus::Transferred,
                transfer_id: None,
                payout_id: None,
                sweep_payout_id: Some(external("po-sweep-1")),
                failure_reason: None,
            })
            .await
            .expect("first sweep paid");
        service
            .reopen_failed_sweep(&WithdrawalTransition {
                operation: operation("withdraw:sweep:failed-1", 114),
                withdrawal_id: withdrawal_id.clone(),
                expected_status: WithdrawalStatus::Paid,
                transfer_id: None,
                payout_id: None,
                sweep_payout_id: Some(external("po-sweep-1")),
                failure_reason: Some("bank bounce".into()),
            })
            .await
            .expect("reopen failed sweep");

        let stale_paid = service
            .mark_sweep_paid(&WithdrawalTransition {
                operation: operation("withdraw:sweep:stale-paid-1", 115),
                withdrawal_id: withdrawal_id.clone(),
                expected_status: WithdrawalStatus::Transferred,
                transfer_id: None,
                payout_id: None,
                sweep_payout_id: Some(external("po-sweep-1")),
                failure_reason: None,
            })
            .await;
        assert!(matches!(stale_paid, Err(LedgerError::StaleVersion)));
        let reopened: (String, String) = sqlx::query_as(
            "SELECT status, sweep_payout_id FROM public.stripe_withdrawals WHERE id = $1",
        )
        .bind(withdrawal_id.as_str())
        .fetch_one(&pool)
        .await
        .expect("reopened withdrawal");
        assert_eq!(
            reopened,
            ("transferred".to_owned(), "po-sweep-1".to_owned())
        );

        service
            .mark_sweep_paid(&WithdrawalTransition {
                operation: operation("withdraw:sweep:paid-2", 116),
                withdrawal_id,
                expected_status: WithdrawalStatus::Transferred,
                transfer_id: None,
                payout_id: None,
                sweep_payout_id: Some(external("po-sweep-2")),
                failure_reason: None,
            })
            .await
            .expect("next distinct sweep paid");

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn sweep_failure_tombstone_serializes_failure_before_paid_and_concurrent_delivery() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        seed_balance(&pool, "consumer", 2_000, 2_000).await;
        let service = LedgerService::new(database.clone());

        let failure_first =
            WithdrawalId::new("withdraw-sweep-failure-first").expect("withdrawal");
        service
            .create_withdrawal(&WithdrawalRequest {
                operation: operation("withdraw:sweep:failure-first:create", 117),
                outbox_id: darkbloom_coordinator_server::ledger::OutboxId::random(),
                withdrawal_id: failure_first.clone(),
                account_id: account("consumer"),
                stripe_account_id: external("acct-sweep"),
                amount: amount(500),
                fee: amount(0),
                method: "standard".into(),
                idempotency_key: "withdraw:failure-first:idempotency".into(),
                payload_digest: canonical_json_digest(&json!({"withdrawal": "failure-first"}))
                    .expect("payload digest"),
                external_payload: json!({"withdrawal": "failure-first"}),
            })
            .await
            .expect("create failure-first withdrawal");
        service
            .mark_withdrawal(
                &WithdrawalTransition {
                    operation: operation("withdraw:sweep:failure-first:transferred", 118),
                    withdrawal_id: failure_first.clone(),
                    expected_status: WithdrawalStatus::Pending,
                    transfer_id: Some(external("tr-failure-first")),
                    payout_id: None,
                    sweep_payout_id: None,
                    failure_reason: None,
                },
                WithdrawalStatus::Transferred,
            )
            .await
            .expect("transfer failure-first withdrawal");
        let failure = service
            .reopen_failed_sweep(&WithdrawalTransition {
                operation: operation("withdraw:sweep:failure-first:failed", 119),
                withdrawal_id: failure_first.clone(),
                expected_status: WithdrawalStatus::Paid,
                transfer_id: None,
                payout_id: None,
                sweep_payout_id: Some(external("po-failure-first")),
                failure_reason: Some("failure arrived before stale paid".into()),
            })
            .await
            .expect("record failure-first tombstone");
        assert_eq!(failure.status, WithdrawalStatus::Transferred);
        assert!(matches!(
            service
                .mark_sweep_paid(&WithdrawalTransition {
                    operation: operation("withdraw:sweep:failure-first:paid", 120),
                    withdrawal_id: failure_first,
                    expected_status: WithdrawalStatus::Transferred,
                    transfer_id: None,
                    payout_id: None,
                    sweep_payout_id: Some(external("po-failure-first")),
                    failure_reason: None,
                })
                .await,
            Err(LedgerError::StaleVersion)
        ));

        let concurrent =
            WithdrawalId::new("withdraw-sweep-concurrent").expect("concurrent withdrawal");
        service
            .create_withdrawal(&WithdrawalRequest {
                operation: operation("withdraw:sweep:concurrent:create", 121),
                outbox_id: darkbloom_coordinator_server::ledger::OutboxId::random(),
                withdrawal_id: concurrent.clone(),
                account_id: account("consumer"),
                stripe_account_id: external("acct-sweep"),
                amount: amount(500),
                fee: amount(0),
                method: "standard".into(),
                idempotency_key: "withdraw:concurrent:idempotency".into(),
                payload_digest: canonical_json_digest(&json!({"withdrawal": "concurrent"}))
                    .expect("payload digest"),
                external_payload: json!({"withdrawal": "concurrent"}),
            })
            .await
            .expect("create concurrent withdrawal");
        service
            .mark_withdrawal(
                &WithdrawalTransition {
                    operation: operation("withdraw:sweep:concurrent:transferred", 122),
                    withdrawal_id: concurrent.clone(),
                    expected_status: WithdrawalStatus::Pending,
                    transfer_id: Some(external("tr-concurrent")),
                    payout_id: None,
                    sweep_payout_id: None,
                    failure_reason: None,
                },
                WithdrawalStatus::Transferred,
            )
            .await
            .expect("transfer concurrent withdrawal");
        let paid_service = service.clone();
        let paid_id = concurrent.clone();
        let paid = tokio::spawn(async move {
            paid_service
                .mark_sweep_paid(&WithdrawalTransition {
                    operation: operation("withdraw:sweep:concurrent:paid", 123),
                    withdrawal_id: paid_id,
                    expected_status: WithdrawalStatus::Transferred,
                    transfer_id: None,
                    payout_id: None,
                    sweep_payout_id: Some(external("po-concurrent")),
                    failure_reason: None,
                })
                .await
        });
        let failure_service = service.clone();
        let failure_id = concurrent.clone();
        let failed = tokio::spawn(async move {
            failure_service
                .reopen_failed_sweep(&WithdrawalTransition {
                    operation: operation("withdraw:sweep:concurrent:failed", 124),
                    withdrawal_id: failure_id,
                    expected_status: WithdrawalStatus::Paid,
                    transfer_id: None,
                    payout_id: None,
                    sweep_payout_id: Some(external("po-concurrent")),
                    failure_reason: Some("concurrent bank bounce".into()),
                })
                .await
        });
        let (paid, failed) = tokio::join!(paid, failed);
        let paid = paid.expect("paid task");
        assert!(
            paid.is_ok() || matches!(paid, Err(LedgerError::StaleVersion)),
            "unexpected paid result: {paid:?}"
        );
        assert_eq!(
            failed
                .expect("failure task")
                .expect("concurrent failure disposition")
                .status,
            WithdrawalStatus::Transferred
        );
        let final_state: (String, String) = sqlx::query_as(
            "SELECT status, sweep_payout_id FROM public.stripe_withdrawals WHERE id = $1",
        )
        .bind(concurrent.as_str())
        .fetch_one(&pool)
        .await
        .expect("concurrent withdrawal state");
        assert_eq!(final_state.0, "transferred");
        assert!(
            final_state.1.is_empty() || final_state.1 == "po-concurrent",
            "sweep stamp must reflect one of the two serialized event orders: {final_state:?}"
        );
        assert!(matches!(
            service
                .mark_sweep_paid(&WithdrawalTransition {
                    operation: operation("withdraw:sweep:concurrent:stale-paid", 125),
                    withdrawal_id: concurrent,
                    expected_status: WithdrawalStatus::Transferred,
                    transfer_id: None,
                    payout_id: None,
                    sweep_payout_id: Some(external("po-concurrent")),
                    failure_reason: None,
                })
                .await,
            Err(LedgerError::StaleVersion)
        ));
        let tombstones: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM public.stripe_sweep_failures WHERE payout_id IN ('po-failure-first', 'po-concurrent')",
        )
        .fetch_one(&pool)
        .await
        .expect("sweep failure tombstones");
        assert_eq!(tombstones, 2);

        shutdown(database, ownership, pool).await;
    })
    .await;
}

async fn service_database(url: &str) -> (Database, CoordinatorOwnership, PgPool) {
    service_database_with_timeout(url, Duration::from_secs(5)).await
}

async fn service_database_with_timeout(
    url: &str,
    operation_timeout: Duration,
) -> (Database, CoordinatorOwnership, PgPool) {
    seed_service_schema(url).await;
    let database = Database::connect(url, 16, operation_timeout)
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

async fn seed_balance(pool: &PgPool, account: &str, total: i64, withdrawable: i64) {
    sqlx::query(
        "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ($1, $2, $3)",
    )
    .bind(account)
    .bind(total)
    .bind(withdrawable)
    .execute(pool)
    .await
    .expect("seed balance");
}

async fn mark_started(
    service: &LedgerService,
    job_id: JobId,
    job_version: Version,
    job_state: JobState,
    attempt_id: AttemptId,
) -> darkbloom_coordinator_server::ledger::StartDispatchResult {
    let queued = service
        .record_start_dispatch(&StartDispatchRequest {
            job_id,
            expected_job_version: job_version,
            expected_job_state: job_state,
            attempt_id,
            expected_attempt_version: version(1),
            expected_attempt_state: AttemptState::NotSent,
            disposition: StartDispatchDisposition::Queued,
        })
        .await
        .expect("record queued Start");
    service
        .record_start_dispatch(&StartDispatchRequest {
            job_id,
            expected_job_version: queued.job_version,
            expected_job_state: queued.job_state,
            attempt_id,
            expected_attempt_version: queued.attempt_version,
            expected_attempt_state: queued.attempt_state,
            disposition: StartDispatchDisposition::Running,
        })
        .await
        .expect("record StartAck")
}

async fn balance(pool: &PgPool, account: &str) -> (i64, i64) {
    sqlx::query_as(
        "SELECT balance_micro_usd, withdrawable_micro_usd FROM public.balances WHERE account_id = $1",
    )
    .bind(account)
    .fetch_one(pool)
    .await
    .expect("balance")
}

async fn seed_pending_terminal(pool: &PgPool, job_id: JobId, facts: &TerminalFacts) {
    let outcome = match facts.outcome {
        TerminalOutcome::Completed => "completed",
        TerminalOutcome::Cancelled => "cancelled",
        TerminalOutcome::Error => "error",
    };
    sqlx::query(
        r#"
        INSERT INTO rust_coord.provider_terminals (
            terminal_id,
            job_id,
            attempt_id,
            provider_id,
            provider_process_generation_id,
            origin_session_epoch,
            terminal_digest,
            raw_terminal,
            outcome,
            error_class,
            prompt_tokens,
            completion_tokens,
            reasoning_tokens,
            response_digest,
            rolling_digest,
            final_generated_tokens,
            provider_signature,
            owner_epoch
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
            $14, $15, $16, $17, 1
        )
        "#,
    )
    .bind(facts.terminal_id.as_uuid())
    .bind(job_id.as_uuid())
    .bind(facts.attempt_id.as_uuid())
    .bind(facts.provider_id)
    .bind(facts.provider_process_generation_id)
    .bind(facts.origin_session_epoch.as_i64())
    .bind(facts.terminal_digest.as_bytes().as_slice())
    .bind(Json(&facts.raw_terminal))
    .bind(outcome)
    .bind(facts.error_class.as_deref())
    .bind(i64::try_from(facts.prompt_tokens).expect("test prompt tokens"))
    .bind(i64::try_from(facts.completion_tokens).expect("test completion tokens"))
    .bind(i64::try_from(facts.reasoning_tokens).expect("test reasoning tokens"))
    .bind(facts.response_digest.as_bytes().as_slice())
    .bind(facts.rolling_digest.as_bytes().as_slice())
    .bind(i64::try_from(facts.final_generated_tokens).expect("test generated tokens"))
    .bind(facts.provider_signature.as_slice())
    .execute(pool)
    .await
    .expect("seed pending terminal");
}

async fn seed_hard_untrust(
    pool: &PgPool,
    provider_id: Uuid,
    session_epoch: Version,
    evidence_digest: Digest,
) {
    sqlx::query(
        r#"
        INSERT INTO rust_coord.provider_hard_untrust_epochs (
            provider_id,
            hard_untrust_epoch,
            reason,
            evidence_digest,
            owner_epoch
        ) VALUES ($1, $2, 'test_hard_untrust', $3, 1)
        "#,
    )
    .bind(provider_id)
    .bind(session_epoch.as_i64())
    .bind(evidence_digest.as_bytes().as_slice())
    .execute(pool)
    .await
    .expect("seed hard-untrust epoch");
}

fn standard_prepared(
    operation_key: &str,
    operation_digest: u8,
    job_id: JobId,
    expected_version: Version,
    attempt_id: AttemptId,
    provider_id: Uuid,
    provider_process_generation_id: Uuid,
) -> PreparedReservation {
    PreparedReservation {
        operation: operation(operation_key, operation_digest),
        job_id,
        expected_version,
        expected_state: JobState::Reserved,
        attempt_id,
        attempt_kind: DurableAttemptKind::Primary,
        provider_id,
        provider_process_generation_id,
        session_epoch: version(1),
        lease_id: Uuid::new_v4(),
        permit_id: Uuid::new_v4(),
        dispatch_nonce: digest(operation_digest.wrapping_add(1)),
        request_digest: digest(operation_digest.wrapping_add(2)),
        concrete_model: "model/build".into(),
        public_model: "model".into(),
        pricing_version: version(1),
        rounding_version: version(1),
        billable_input_tokens: 100,
        bounded_output_tokens: 100,
        input_micro_usd_per_million: amount(1_000_000),
        output_micro_usd_per_million: amount(2_000_000),
        provider_account_id: account("provider"),
        platform_account_id: account("platform"),
        referral_account_id: Some(account("referrer")),
        maximum_provider_payout: amount(225),
        maximum_platform_fee: amount(60),
        maximum_referral_reward: amount(15),
        provider_share_ppm: 750_000,
        referral_share_ppm: 200_000,
        execution_worker_id: None,
        start_deadline_millis: 15_000,
    }
}

fn reserve_request(key: &str, byte: u8, account_id: &str, amount_value: u64) -> ReserveRequest {
    ReserveRequest {
        operation: operation(key, byte),
        job_id: JobId::random(),
        request_id: Uuid::new_v4(),
        reservation_id: ReservationId::random(),
        account_id: account(account_id),
        api_key_id: Arc::from("api-key"),
        consumer_key_hash: Arc::from("consumer-key-hash"),
        amount: amount(amount_value),
        request_deadline_epoch_millis: TEST_REQUEST_DEADLINE_EPOCH_MILLIS,
        execution_worker_id: None,
        execution_lease_millis: None,
        provisional_provider_id: None,
        provisional_session_epoch: None,
        public_model: Arc::from(""),
        concrete_model: Arc::from(""),
        api_key_limit_micro_usd: None,
        api_key_controlled: false,
    }
}

fn operation(key: &str, byte: u8) -> Operation {
    Operation::new(OperationKey::new(key).expect("operation key"), digest(byte))
}

fn digest(byte: u8) -> Digest {
    Digest::new([byte; 32])
}

fn digest_number(value: u64) -> Digest {
    let mut bytes = [0_u8; 32];
    bytes[..8].copy_from_slice(&value.to_be_bytes());
    Digest::new(bytes)
}

fn current_epoch_millis() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("test clock after Unix epoch")
            .as_millis(),
    )
    .expect("test epoch fits u64")
}

fn account(value: &str) -> AccountId {
    AccountId::new(value).expect("account")
}

fn external(value: &str) -> ExternalId {
    ExternalId::new(value).expect("external id")
}

fn amount(value: u64) -> LedgerAmount {
    LedgerAmount::new(value).expect("amount")
}

fn version(value: u64) -> Version {
    Version::new(value).expect("version")
}
