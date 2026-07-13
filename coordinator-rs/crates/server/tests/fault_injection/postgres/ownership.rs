use super::{common::*, *};
use sqlx::{Connection as _, PgConnection};

#[tokio::test(flavor = "current_thread")]
#[allow(clippy::await_holding_lock)]
async fn postgres_schema_and_ownership_faults_fail_closed() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    support::with_isolated_database(|url| async move {
        support::seed_service_schema(&url).await;

        let checksum_fault =
            arm(FaultPoint::MigrationChecksum, FaultAction::Fail).expect("arm checksum fault");
        let checksum_error = Database::connect(&url, 4, Duration::from_secs(3))
            .await
            .expect_err("checksum fault allowed serving startup");
        checksum_fault
            .wait_until_hit(Duration::from_secs(1))
            .await
            .expect("checksum checkpoint");
        assert!(matches!(
            checksum_error,
            DatabaseError::Schema(SchemaError::InjectedFault("migration_checksum"))
        ));
        record_receipt(
            "migration_checksum_fails_startup_closed",
            &[&checksum_fault],
            &["quiescence_ownership_fencing"],
        );
        drop(checksum_fault);

        let database = Database::connect(&url, 4, Duration::from_secs(3))
            .await
            .expect("connect after checksum fault");
        let lock_fault =
            arm(FaultPoint::MigrationLock, FaultAction::Fail).expect("arm migration lock fault");
        let lock_error = CoordinatorOwnership::configure(&database, &url, true)
            .await
            .expect_err("migration handoff fault allowed ownership");
        lock_fault
            .wait_until_hit(Duration::from_secs(1))
            .await
            .expect("migration lock checkpoint");
        assert!(matches!(
            lock_error,
            OwnershipError::InjectedFault("migration_lock")
        ));
        record_receipt(
            "migration_lock_fails_ownership_closed",
            &[&lock_fault],
            &["quiescence_ownership_fencing"],
        );
        drop(lock_fault);

        let ownership_fault = arm(FaultPoint::OwnershipConnectionLoss, FaultAction::Fail)
            .expect("arm ownership loss");
        let ownership = CoordinatorOwnership::configure(&database, &url, true)
            .await
            .expect("configure owner after released migration lock");
        ownership_fault
            .wait_until_hit(Duration::from_secs(1))
            .await
            .expect("ownership loss checkpoint");
        assert!(!ownership.status().is_healthy());
        assert!(matches!(
            database
                .begin_owned()
                .await
                .expect_err("lost owner admitted mutation"),
            DatabaseError::Ownership(OwnershipError::Lost)
        ));

        database
            .close(Duration::from_secs(2))
            .await
            .expect("close database after injected ownership loss");
        assert!(matches!(
            ownership
                .release()
                .await
                .expect_err("injected owner released cleanly"),
            OwnershipError::InjectedFault("ownership_connection_loss")
        ));
        record_receipt(
            "ownership_connection_loss_fences_mutations",
            &[&ownership_fault],
            &["quiescence_ownership_fencing"],
        );
    })
    .await;
}

#[tokio::test(flavor = "current_thread")]
#[allow(clippy::await_holding_lock)]
async fn postgres_connection_termination_quiesces_and_fences_mutations() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    support::with_isolated_database(|url| async move {
        support::seed_service_schema(&url).await;
        let (database, ownership, pool) = service_database(&url).await;
        let mut killer = PgConnection::connect(&url)
            .await
            .expect("connect ownership killer");
        let terminated: bool = sqlx::query_scalar("SELECT pg_terminate_backend($1)")
            .bind(ownership.backend_pid())
            .fetch_one(&mut killer)
            .await
            .expect("terminate ownership connection");
        assert!(terminated);
        timeout(
            Duration::from_secs(2),
            ownership.status().wait_until_unhealthy(),
        )
        .await
        .expect("ownership termination was not observed");
        assert!(matches!(
            database
                .begin_owned()
                .await
                .expect_err("terminated owner admitted mutation"),
            DatabaseError::Ownership(OwnershipError::Lost)
        ));

        killer.close().await.expect("close ownership killer");
        pool.close().await;
        database
            .close(Duration::from_secs(2))
            .await
            .expect("close database after terminated ownership");
        assert!(
            ownership.release().await.is_err(),
            "terminated ownership released cleanly"
        );
    })
    .await;
}
