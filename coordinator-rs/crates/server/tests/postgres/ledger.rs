use std::{sync::Arc, time::Duration};

use darkbloom_coordinator_core::ids::Digest;
use darkbloom_coordinator_server::{
    database::Database,
    ledger::{
        AccountId, AttemptId, ExternalEventId, ExternalId, JobId, JobState, LedgerAmount,
        LedgerError, LedgerService, MutationDisposition, Operation, OperationKey,
        PreparedReservation, ReleaseRequest, ReservationId, ReserveRequest, SettleRequest,
        StripeDeposit, TerminalFacts, TerminalId, TerminalOutcome, Version, WithdrawalDisposition,
        WithdrawalId, WithdrawalRequest, WithdrawalStatus, WithdrawalTransition,
    },
    ownership::CoordinatorOwnership,
    recovery::RecoveryService,
};
use serde_json::json;
use sqlx::{PgPool, types::Json};
use uuid::Uuid;

use super::support::{seed_service_schema, with_isolated_database};

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
            Err(LedgerError::CommitOutcomeUnknown(key))
                if key == absent.operation.key
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
            payload_digest: digest(102),
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
                referral_share_ppm: 0,
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
            maximum_provider_payout: amount(200),
            maximum_platform_fee: amount(80),
            maximum_referral_reward: amount(20),
            referral_share_ppm: 200_000,
        };
        let authorized = service
            .resize_and_authorize(&prepared)
            .await
            .expect("resize and authorize");
        assert_eq!(authorized.total, amount(300));
        assert_eq!(authorized.state, JobState::StartAuthorized);

        let mut settlement = SettleRequest {
            operation: operation("settle:terminal", 14),
            job_id: reserve.job_id,
            expected_job_version: authorized.version,
            expected_job_state: JobState::StartAuthorized,
            expected_attempt_version: version(1),
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
            consumer_key_hash: "key-hash".into(),
        };
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

        seed_pending_terminal(&pool, reserve.job_id, &settlement.terminal).await;
        let terminal_worker = Uuid::new_v4();
        let claimed = RecoveryService::new(database.clone())
            .claim_terminals(terminal_worker, 1, Duration::from_secs(1))
            .await
            .expect("claim pending terminal");
        assert_eq!(claimed.len(), 1);
        settlement.terminal = claimed
            .into_iter()
            .next()
            .expect("claimed terminal")
            .into_terminal_facts();
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
                amount: amount(200),
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
                    referral_share_ppm: 0,
                })
                .await
                .expect("stress authorize");
            settlements.push(SettleRequest {
                operation: Operation::new(
                    OperationKey::new(format!("stress:settle:{index}")).expect("key"),
                    digest_number(1_002 + index * 3),
                ),
                job_id: reserve.job_id,
                expected_job_version: authorized.version,
                expected_job_state: JobState::StartAuthorized,
                expected_attempt_version: version(1),
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
                consumer_key_hash: "stress-hash".into(),
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
                referral_share_ppm: 0,
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
            consumer_key_hash: "hash".into(),
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
            payload_digest: digest(31),
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

fn reserve_request(key: &str, byte: u8, account_id: &str, amount_value: u64) -> ReserveRequest {
    ReserveRequest {
        operation: operation(key, byte),
        job_id: JobId::random(),
        request_id: Uuid::new_v4(),
        reservation_id: ReservationId::random(),
        account_id: account(account_id),
        api_key_id: Arc::from("api-key"),
        amount: amount(amount_value),
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
