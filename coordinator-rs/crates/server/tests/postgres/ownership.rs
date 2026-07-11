use std::time::Duration;

use axum::http::StatusCode;
use darkbloom_coordinator_server::{
    app::{AppState, router},
    database::{Database, DatabaseError},
    ownership::{CoordinatorOwnership, OwnershipError},
    runtime,
};
use sqlx::{Connection, PgConnection};
use tokio::time::timeout;

use super::support::{request_json, reset_schema, with_isolated_database};

#[tokio::test]
async fn rust_ownership_contends_with_rust_and_raw_go_lock() {
    with_isolated_database(|url| async move {
        reset_schema(&url, 4, 2, 4, 4).await;

        let first_database = Database::connect(&url, 4, Duration::from_secs(3))
            .await
            .expect("connect first database");
        let first = CoordinatorOwnership::configure(&first_database, &url, true)
            .await
            .expect("configure first ownership");
        assert_eq!(first.epoch(), 1);

        let second_database = Database::connect(&url, 4, Duration::from_secs(3))
            .await
            .expect("connect second database");
        let contention = CoordinatorOwnership::configure(&second_database, &url, true)
            .await
            .expect_err("a second Rust owner must be rejected");
        assert!(matches!(contention, OwnershipError::AlreadyHeld));

        let mut raw = PgConnection::connect(&url)
            .await
            .expect("connect raw contender");
        let raw_locked: bool = sqlx::query_scalar(
            "SELECT pg_try_advisory_lock(hashtextextended('darkbloom-coordinator-owner', 0))",
        )
        .fetch_one(&mut raw)
        .await
        .expect("try Go-compatible advisory lock");
        assert!(!raw_locked, "raw Go-compatible lock bypassed Rust owner");

        let mut transaction = first_database
            .begin_owned()
            .await
            .expect("begin ownership-verified transaction");
        assert_eq!(transaction.context().epoch(), first.epoch());
        let value: i32 = sqlx::query_scalar("SELECT 1")
            .fetch_one(transaction.connection())
            .await
            .expect("query through owned transaction");
        assert_eq!(value, 1);
        transaction
            .commit()
            .await
            .expect("commit owned transaction");

        first_database
            .close(Duration::from_secs(2))
            .await
            .expect("close first pool before releasing ownership");
        first.release().await.expect("release first ownership");
        let released_owner: String = sqlx::query_scalar(
            "SELECT owner_id FROM public.coordinator_ownership WHERE singleton = TRUE",
        )
        .fetch_one(&mut raw)
        .await
        .expect("read released ownership row");
        assert!(released_owner.is_empty());

        let raw_locked: bool = sqlx::query_scalar(
            "SELECT pg_try_advisory_lock(hashtextextended('darkbloom-coordinator-owner', 0))",
        )
        .fetch_one(&mut raw)
        .await
        .expect("acquire raw Go-compatible advisory lock");
        assert!(raw_locked);
        let raw_contention = CoordinatorOwnership::configure(&second_database, &url, true)
            .await
            .expect_err("raw Go-compatible owner must block Rust");
        assert!(matches!(raw_contention, OwnershipError::AlreadyHeld));
        let raw_unlocked: bool = sqlx::query_scalar(
            "SELECT pg_advisory_unlock(hashtextextended('darkbloom-coordinator-owner', 0))",
        )
        .fetch_one(&mut raw)
        .await
        .expect("release raw lock");
        assert!(raw_unlocked);
        raw.close().await.expect("close raw contender");

        let disabled = CoordinatorOwnership::configure(&second_database, &url, false)
            .await
            .expect_err("ownership cannot be disabled after activation");
        assert!(matches!(
            disabled,
            OwnershipError::CannotDisableAfterActivation
        ));

        let second = CoordinatorOwnership::configure(&second_database, &url, true)
            .await
            .expect("configure second ownership after handoff");
        assert_eq!(second.epoch(), 2);
        second_database
            .close(Duration::from_secs(2))
            .await
            .expect("close second pool before releasing ownership");
        second.release().await.expect("release second ownership");
    })
    .await;
}

#[tokio::test]
async fn disabled_legacy_mode_retains_primary_lock_and_releases_cleanly() {
    with_isolated_database(|url| async move {
        reset_schema(&url, 4, 2, 4, 4).await;

        let database = Database::connect(&url, 4, Duration::from_secs(3))
            .await
            .expect("connect legacy database");
        let ownership = CoordinatorOwnership::configure(&database, &url, false)
            .await
            .expect("configure disabled legacy ownership");
        assert!(!ownership.fence().context().epoch_active());
        assert_eq!(ownership.epoch(), 0);

        let mut inspector = PgConnection::connect(&url)
            .await
            .expect("connect legacy ownership inspector");
        let raw_locked: bool = sqlx::query_scalar(
            "SELECT pg_try_advisory_lock(hashtextextended('darkbloom-coordinator-owner', 0))",
        )
        .fetch_one(&mut inspector)
        .await
        .expect("contend with disabled legacy owner");
        assert!(
            !raw_locked,
            "disabled legacy mode did not retain the primary lock"
        );
        let marker_count: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM public.schema_migrations WHERE id = 'coordinator_ownership_activated'",
        )
        .fetch_one(&mut inspector)
        .await
        .expect("count activation marker");
        assert_eq!(marker_count, 0);

        database
            .close(Duration::from_secs(2))
            .await
            .expect("close legacy serving pool");
        ownership
            .release()
            .await
            .expect("release disabled legacy ownership");

        let raw_locked: bool = sqlx::query_scalar(
            "SELECT pg_try_advisory_lock(hashtextextended('darkbloom-coordinator-owner', 0))",
        )
        .fetch_one(&mut inspector)
        .await
        .expect("acquire primary after legacy release");
        assert!(raw_locked);
        let raw_unlocked: bool = sqlx::query_scalar(
            "SELECT pg_advisory_unlock(hashtextextended('darkbloom-coordinator-owner', 0))",
        )
        .fetch_one(&mut inspector)
        .await
        .expect("release primary after legacy release");
        assert!(raw_unlocked);
        inspector.close().await.expect("close legacy inspector");
    })
    .await;
}

#[tokio::test]
async fn disabled_to_enabled_handoff_drains_and_fences_stale_checkout() {
    with_isolated_database(|url| async move {
        reset_schema(&url, 4, 2, 4, 4).await;
        let mut control = PgConnection::connect(&url)
            .await
            .expect("connect handoff control");
        sqlx::query(
            "CREATE TABLE public.ownership_fence_writes (value TEXT PRIMARY KEY)",
        )
        .execute(&mut control)
        .await
        .expect("create fence write probe");

        let legacy_database = Database::connect(&url, 4, Duration::from_secs(3))
            .await
            .expect("connect disabled legacy database");
        let legacy = CoordinatorOwnership::configure(&legacy_database, &url, false)
            .await
            .expect("configure disabled legacy owner");
        let enabled_database = Database::connect(&url, 4, Duration::from_secs(3))
            .await
            .expect("connect enabled successor database");
        let overlap = CoordinatorOwnership::configure(&enabled_database, &url, true)
            .await
            .expect_err("enabled successor overlapped live disabled owner");
        assert!(matches!(overlap, OwnershipError::AlreadyHeld));

        let mut draining = legacy_database
            .begin_owned()
            .await
            .expect("begin old in-flight transaction");
        sqlx::query("INSERT INTO public.ownership_fence_writes (value) VALUES ('draining')")
            .execute(draining.connection())
            .await
            .expect("stage old in-flight write");

        let terminated: bool = sqlx::query_scalar("SELECT pg_terminate_backend($1)")
            .bind(legacy.backend_pid())
            .fetch_one(&mut control)
            .await
            .expect("terminate disabled primary backend");
        assert!(terminated);
        wait_until_primary_is_free(&mut control).await;

        let successor_url = url.clone();
        let successor = tokio::spawn(async move {
            let ownership =
                CoordinatorOwnership::configure(&enabled_database, &successor_url, true)
                    .await
                    .expect("configure enabled successor");
            (enabled_database, ownership)
        });
        wait_until_mutation_handoff_is_waiting(&mut control).await;
        assert!(
            !successor.is_finished(),
            "successor bypassed old shared mutation lock"
        );
        let marker_count: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM public.schema_migrations WHERE id = 'coordinator_ownership_activated'",
        )
        .fetch_one(&mut control)
        .await
        .expect("count marker during blocked handoff");
        assert_eq!(
            marker_count, 0,
            "successor changed authority before old checkout drained"
        );

        let stale_database = legacy_database.clone();
        let stale_checkout = tokio::spawn(async move {
            match stale_database.begin_owned().await {
                Ok(mut transaction) => {
                    sqlx::query(
                        "INSERT INTO public.ownership_fence_writes (value) VALUES ('stale')",
                    )
                    .execute(transaction.connection())
                    .await
                    .map_err(|source| DatabaseError::Transaction {
                        operation: "execute stale probe",
                        source,
                    })?;
                    transaction.commit().await
                }
                Err(error) => Err(error),
            }
        });

        draining
            .commit()
            .await
            .expect("commit old in-flight transaction");
        let (enabled_database, enabled) = timeout(Duration::from_secs(2), successor)
            .await
            .expect("enabled successor remained blocked after drain")
            .expect("enabled successor task panicked");
        assert_eq!(enabled.epoch(), 1);

        let stale = timeout(Duration::from_millis(250), stale_checkout)
            .await
            .expect("stale checkout remained blocked after handoff")
            .expect("stale checkout task panicked")
        .expect_err("stale pool checkout received write authority");
        assert!(matches!(
            stale,
            DatabaseError::Ownership(OwnershipError::Lost)
        ));
        let writes: Vec<String> =
            sqlx::query_scalar("SELECT value FROM public.ownership_fence_writes ORDER BY value")
                .fetch_all(&mut control)
                .await
                .expect("read fenced writes");
        assert_eq!(writes, ["draining"]);

        legacy_database
            .close(Duration::from_secs(2))
            .await
            .expect("close stale legacy pool");
        assert!(
            legacy.release().await.is_err(),
            "terminated legacy primary released cleanly"
        );
        enabled_database
            .close(Duration::from_secs(2))
            .await
            .expect("close enabled successor pool");
        enabled
            .release()
            .await
            .expect("release enabled successor");
        control.close().await.expect("close handoff control");
    })
    .await;
}

#[tokio::test]
async fn ownership_connection_loss_fails_readiness_and_stops_runtime() {
    with_isolated_database(|url| async move {
        reset_schema(&url, 4, 2, 4, 4).await;

        let database = Database::connect(&url, 4, Duration::from_secs(3))
            .await
            .expect("connect database");
        let ownership = CoordinatorOwnership::configure(&database, &url, true)
            .await
            .expect("configure ownership");
        let status = ownership.status();
        let app = router(AppState::new(database.clone()).with_ownership(status.clone()));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind runtime listener");
        let runtime = tokio::spawn(runtime::serve(
            listener,
            app.clone(),
            {
                let status = status.clone();
                async move { status.wait_until_unhealthy().await }
            },
            Duration::from_secs(2),
        ));

        let mut killer = PgConnection::connect(&url)
            .await
            .expect("connect ownership killer");
        let terminated: bool = sqlx::query_scalar("SELECT pg_terminate_backend($1)")
            .bind(ownership.backend_pid())
            .fetch_one(&mut killer)
            .await
            .expect("terminate ownership backend");
        assert!(terminated);
        wait_until_primary_is_free(&mut killer).await;
        let immediate_fence = timeout(Duration::from_millis(250), database.begin_owned())
            .await
            .expect("serving pool waited for periodic ownership monitor")
            .expect_err("serving pool admitted a write after primary connection loss");
        assert!(matches!(
            immediate_fence,
            DatabaseError::Ownership(OwnershipError::Lost)
        ));
        timeout(Duration::from_secs(3), status.wait_until_unhealthy())
            .await
            .expect("ownership monitor did not report loss");

        let (ready_status, payload) = request_json(&app, "/readyz").await;
        assert_eq!(ready_status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(
            payload,
            serde_json::json!({"draining": false, "inflight": 0, "ready": false})
        );
        timeout(Duration::from_secs(3), runtime)
            .await
            .expect("runtime did not shut down after ownership loss")
            .expect("runtime task panicked")
            .expect("runtime shutdown failed");

        killer.close().await.expect("close ownership killer");
        database
            .close(Duration::from_secs(2))
            .await
            .expect("close database after ownership loss");
        assert!(
            ownership.release().await.is_err(),
            "lost ownership unexpectedly released cleanly"
        );
    })
    .await;
}

async fn wait_until_mutation_handoff_is_waiting(connection: &mut PgConnection) {
    timeout(Duration::from_secs(2), async {
        loop {
            let waiting: bool = sqlx::query_scalar(
                r#"
                SELECT EXISTS (
                    SELECT 1
                    FROM pg_locks
                    WHERE locktype = 'advisory'
                      AND database = (
                          SELECT oid FROM pg_database WHERE datname = current_database()
                      )
                      AND classid = (
                          (hashtextextended('darkbloom-coordinator-mutation', 0) >> 32)
                          & 4294967295
                      )::OID
                      AND objid = (
                          hashtextextended('darkbloom-coordinator-mutation', 0)
                          & 4294967295
                      )::OID
                      AND objsubid = 1
                      AND mode = 'ExclusiveLock'
                      AND NOT granted
                )
                "#,
            )
            .fetch_one(&mut *connection)
            .await
            .expect("inspect pending mutation handoff lock");
            if waiting {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("enabled successor did not wait for old shared mutation lock");
}

async fn wait_until_primary_is_free(connection: &mut PgConnection) {
    timeout(Duration::from_secs(2), async {
        loop {
            let acquired: bool = sqlx::query_scalar(
                "SELECT pg_try_advisory_lock(hashtextextended('darkbloom-coordinator-owner', 0))",
            )
            .fetch_one(&mut *connection)
            .await
            .expect("probe primary lock after backend termination");
            if acquired {
                let unlocked: bool = sqlx::query_scalar(
                    "SELECT pg_advisory_unlock(hashtextextended('darkbloom-coordinator-owner', 0))",
                )
                .fetch_one(&mut *connection)
                .await
                .expect("release primary post-termination probe");
                assert!(unlocked);
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("terminated primary backend retained its lock");
}
