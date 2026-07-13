use super::{common::*, *};
use darkbloom_coordinator_server::projection::FeeProjectionService;

#[tokio::test(flavor = "current_thread")]
#[allow(clippy::await_holding_lock)]
async fn postgres_fee_projection_fault_recovers_same_lease_once() {
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
        .expect("seed fee source balance");
        let reserve = reserve_request();
        LedgerService::new(database.clone())
            .reserve(&reserve)
            .await
            .expect("reserve fee source job");
        let operation_id: Uuid = sqlx::query_scalar(
            "SELECT operation_id FROM rust_coord.financial_operations WHERE operation_key = $1",
        )
        .bind(reserve.operation.key.as_str())
        .fetch_one(&pool)
        .await
        .expect("reserve operation id");
        let allocation_id = Uuid::new_v4();
        sqlx::query(
            r#"
            INSERT INTO rust_coord.fee_allocations (
                allocation_id, operation_key, job_id, financial_operation_id,
                kind, source_account_id, beneficiary_account_id,
                amount_micro_usd, owner_epoch
            ) VALUES (
                $1, 'fee:fault:same-lease', $2, $3, 'platform',
                'fault-consumer', 'platform', 10, 1
            )
            "#,
        )
        .bind(allocation_id)
        .bind(reserve.job_id.as_uuid())
        .bind(operation_id)
        .execute(&pool)
        .await
        .expect("seed fee allocation");

        let projection = FeeProjectionService::new(database.clone());
        let worker = Uuid::new_v4();
        let batch = projection
            .claim("legacy-fees", worker, 1, Duration::from_secs(5))
            .await
            .expect("claim fee allocation");
        assert_eq!(batch.allocations.len(), 1);
        let fault =
            arm(FaultPoint::FeeProjection, FaultAction::Fail).expect("arm fee projection fault");
        assert!(matches!(
            projection.complete(&batch, worker).await,
            Err(LedgerError::Timeout)
        ));
        fault
            .wait_until_hit(Duration::from_secs(1))
            .await
            .expect("fee projection checkpoint");

        let retained: (String, Option<Uuid>) = sqlx::query_as(
            "SELECT status, worker_owner FROM rust_coord.fee_allocations WHERE allocation_id = $1",
        )
        .bind(allocation_id)
        .fetch_one(&pool)
        .await
        .expect("faulted fee allocation");
        assert_eq!(
            retained,
            ("processing".to_owned(), Some(worker)),
            "fault discarded or transferred the live lease"
        );
        projection
            .complete(&batch, worker)
            .await
            .expect("same worker resumes the same fee lease");
        assert!(matches!(
            projection.complete(&batch, worker).await,
            Err(LedgerError::StaleVersion)
        ));
        let projected: (String, i64) = sqlx::query_as(
            r#"
            SELECT status, (
                SELECT count(*) FROM rust_coord.fee_allocations
                WHERE operation_key = 'fee:fault:same-lease'
            )::BIGINT
            FROM rust_coord.fee_allocations
            WHERE allocation_id = $1
            "#,
        )
        .bind(allocation_id)
        .fetch_one(&pool)
        .await
        .expect("projected fee allocation");
        assert_eq!(projected, ("projected".to_owned(), 1));
        record_receipt(
            "fee_projection_recovers_same_lease_once",
            &[&fault],
            &["exactly_one_disposition", "same_lease_recovery"],
        );
        shutdown(database, ownership, pool).await;
    })
    .await;
}
