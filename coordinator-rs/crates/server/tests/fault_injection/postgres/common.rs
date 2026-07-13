use super::*;

pub(super) async fn service_database(url: &str) -> (Database, CoordinatorOwnership, PgPool) {
    service_database_without_seed(url).await
}

pub(super) async fn service_database_without_seed(
    url: &str,
) -> (Database, CoordinatorOwnership, PgPool) {
    let database = Database::connect(url, 8, Duration::from_secs(5))
        .await
        .expect("connect service database");
    let ownership = CoordinatorOwnership::configure(&database, url, true)
        .await
        .expect("configure ownership");
    let pool = PgPool::connect(url).await.expect("inspection pool");
    (database, ownership, pool)
}

pub(super) async fn shutdown(database: Database, ownership: CoordinatorOwnership, pool: PgPool) {
    pool.close().await;
    database
        .close(Duration::from_secs(2))
        .await
        .expect("close service database");
    ownership.release().await.expect("release ownership");
}

pub(super) fn reserve_request() -> ReserveRequest {
    ReserveRequest {
        operation: Operation::new(
            OperationKey::new("fault:reserve:exactly-once").expect("operation key"),
            Digest::new([5; 32]),
        ),
        job_id: JobId::random(),
        request_id: Uuid::new_v4(),
        reservation_id: ReservationId::random(),
        account_id: AccountId::new("fault-consumer").expect("account"),
        api_key_id: "fault-key".into(),
        consumer_key_hash: "fault-key-hash".into(),
        amount: LedgerAmount::new(100).expect("amount"),
        request_deadline_epoch_millis: REQUEST_DEADLINE_EPOCH_MILLIS,
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
