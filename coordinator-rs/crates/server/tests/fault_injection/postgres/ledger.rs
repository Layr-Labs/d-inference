use super::{common::*, *};
use darkbloom_coordinator_server::ledger::{
    AttemptId, DurableAttemptKind, JobState, PreparedReservation, Version,
};

#[tokio::test(flavor = "current_thread")]
#[allow(clippy::await_holding_lock)]
async fn postgres_reserve_commit_fault_is_exactly_once_across_restart() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    support::with_isolated_database(|url| async move {
        support::seed_service_schema(&url).await;
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('fault-consumer', 1000, 1000)",
        )
        .execute(&pool)
        .await
        .expect("seed consumer balance");
        let request = reserve_request();
        let fault = arm(FaultPoint::ReserveCommit, FaultAction::Fail).expect("arm reserve commit");
        let error = LedgerService::new(database.clone())
            .reserve(&request)
            .await
            .expect_err("post-commit fault must be ambiguous");
        fault
            .wait_until_hit(Duration::from_secs(1))
            .await
            .expect("reserve commit hit");
        assert!(matches!(error, LedgerError::CommitOutcomeUnknown { .. }));
        assert_reserve_applied_once(&pool).await;
        shutdown(database, ownership, pool).await;

        let (database, ownership, pool) = service_database_without_seed(&url).await;
        let replay = LedgerService::new(database.clone())
            .reserve(&request)
            .await
            .expect("reconcile same operation after restart");
        assert_eq!(replay.disposition, MutationDisposition::Replayed);
        assert_reserve_applied_once(&pool).await;
        record_receipt(
            "reserve_commit_is_exactly_once_across_postgres_restart",
            &[&fault],
            &["exactly_one_disposition", "no_double_money_mutation"],
        );
        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test(flavor = "current_thread")]
#[allow(clippy::await_holding_lock)]
async fn postgres_resize_authorization_fault_recovers_without_failover_or_double_charge() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    support::with_isolated_database(|url| async move {
        support::seed_service_schema(&url).await;
        let (database, ownership, pool) = service_database(&url).await;
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('fault-consumer', 1000, 1000)",
        )
        .execute(&pool)
        .await
        .expect("seed resize consumer balance");

        let reserve = reserve_request();
        let service = LedgerService::new(database.clone());
        let reserved = service.reserve(&reserve).await.expect("reserve before resize");
        let provider_id = Uuid::new_v4();
        let prepared = prepared_reservation(
            &reserve,
            reserved.version,
            provider_id,
            "fault:resize:exactly-once",
        );
        let fault = arm(FaultPoint::ResizeAuthorization, FaultAction::Fail)
            .expect("arm resize authorization");
        let error = service
            .resize_and_authorize(&prepared)
            .await
            .expect_err("post-commit resize fault must be ambiguous");
        fault
            .wait_until_hit(Duration::from_secs(1))
            .await
            .expect("resize authorization hit");
        assert!(matches!(error, LedgerError::CommitOutcomeUnknown { .. }));
        assert_resize_applied_once(&pool, reserve.job_id, provider_id).await;
        shutdown(database, ownership, pool).await;

        let (database, ownership, pool) = service_database_without_seed(&url).await;
        let replay = LedgerService::new(database.clone())
            .resize_and_authorize(&prepared)
            .await
            .expect("reconcile same authorization after restart");
        assert_eq!(replay.disposition, MutationDisposition::Replayed);
        assert_resize_applied_once(&pool, reserve.job_id, provider_id).await;
        record_receipt(
            "resize_authorization_replays_without_double_charge",
            &[&fault],
            &["no_double_money_mutation", "no_failover_after_auth"],
        );
        shutdown(database, ownership, pool).await;
    })
    .await;
}

fn prepared_reservation(
    reserve: &ReserveRequest,
    expected_version: Version,
    provider_id: Uuid,
    operation_key: &str,
) -> PreparedReservation {
    PreparedReservation {
        operation: Operation::new(
            OperationKey::new(operation_key).expect("resize operation key"),
            Digest::new([17; 32]),
        ),
        job_id: reserve.job_id,
        expected_version,
        expected_state: JobState::Reserved,
        attempt_id: AttemptId::random(),
        attempt_kind: DurableAttemptKind::Primary,
        provider_id,
        provider_process_generation_id: Uuid::new_v4(),
        session_epoch: Version::new(1).expect("session epoch"),
        lease_id: Uuid::new_v4(),
        permit_id: Uuid::new_v4(),
        dispatch_nonce: Digest::new([18; 32]),
        request_digest: Digest::new([19; 32]),
        concrete_model: "model/build".into(),
        public_model: "model".into(),
        pricing_version: Version::new(1).expect("pricing version"),
        rounding_version: Version::new(1).expect("rounding version"),
        billable_input_tokens: 100,
        bounded_output_tokens: 100,
        input_micro_usd_per_million: LedgerAmount::new(1_000_000).expect("input rate"),
        output_micro_usd_per_million: LedgerAmount::new(2_000_000).expect("output rate"),
        provider_account_id: AccountId::new("provider").expect("provider account"),
        platform_account_id: AccountId::new("platform").expect("platform account"),
        referral_account_id: Some(AccountId::new("referrer").expect("referrer account")),
        maximum_provider_payout: LedgerAmount::new(225).expect("provider maximum"),
        maximum_platform_fee: LedgerAmount::new(60).expect("platform maximum"),
        maximum_referral_reward: LedgerAmount::new(15).expect("referral maximum"),
        provider_share_ppm: 750_000,
        referral_share_ppm: 200_000,
        execution_worker_id: None,
        start_deadline_millis: 15_000,
    }
}

async fn assert_reserve_applied_once(pool: &PgPool) {
    let balance: i64 =
        sqlx::query_scalar("SELECT balance_micro_usd FROM public.balances WHERE account_id = $1")
            .bind("fault-consumer")
            .fetch_one(pool)
            .await
            .expect("consumer balance");
    let jobs: i64 =
        sqlx::query_scalar("SELECT count(*) FROM rust_coord.inference_jobs WHERE account_id = $1")
            .bind("fault-consumer")
            .fetch_one(pool)
            .await
            .expect("job count");
    let operations: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM rust_coord.financial_operations WHERE operation_key = $1",
    )
    .bind("fault:reserve:exactly-once")
    .fetch_one(pool)
    .await
    .expect("operation count");
    assert_eq!(balance, 900, "reservation money mutated more than once");
    assert_eq!(jobs, 1, "reservation created multiple dispositions");
    assert_eq!(operations, 1, "operation journal duplicated");
}

async fn assert_resize_applied_once(pool: &PgPool, job_id: JobId, provider_id: Uuid) {
    let balance: i64 =
        sqlx::query_scalar("SELECT balance_micro_usd FROM public.balances WHERE account_id = $1")
            .bind("fault-consumer")
            .fetch_one(pool)
            .await
            .expect("resize consumer balance");
    let job: (String, i64, Option<Uuid>) = sqlx::query_as(
        "SELECT state, reserved_total_micro_usd, provider_id FROM rust_coord.inference_jobs WHERE job_id = $1",
    )
    .bind(job_id.as_uuid())
    .fetch_one(pool)
    .await
    .expect("authorized job");
    let attempts: i64 =
        sqlx::query_scalar("SELECT count(*) FROM rust_coord.inference_attempts WHERE job_id = $1")
            .bind(job_id.as_uuid())
            .fetch_one(pool)
            .await
            .expect("authorized attempt count");
    let operations: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM rust_coord.financial_operations WHERE operation_key = $1",
    )
    .bind("fault:resize:exactly-once")
    .fetch_one(pool)
    .await
    .expect("resize operation count");
    assert_eq!(balance, 700, "authorization money mutated more than once");
    assert_eq!(
        job,
        ("start_authorized".to_owned(), 300, Some(provider_id)),
        "authorization changed provider or disposition"
    );
    assert_eq!(attempts, 1, "authorization failed over after commit");
    assert_eq!(operations, 1, "authorization journal duplicated");
}
