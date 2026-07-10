//! Batch force-settle/recover hold money_fx per job (DECISIONS #139).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use std::time::Duration;
use tower::ServiceExt;

#[tokio::test]
async fn force_settle_batch_blocks_quiescence_while_money_fx_held() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-bfx".into()),
            "bfx-1",
            "pilot-account",
            50_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "bfx-1", "pilot-account")
            .unwrap();
    }

    let fx = state.money_fx.clone();
    let app = router(state.clone());
    let hold = fx.lock().await;

    let batch = {
        let app = app.clone();
        tokio::spawn(async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/force-settle-batch")
                    .header("content-type", "application/json")
                    .body(Body::from(json!({ "actual_micro_usd": 0 }).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap()
        })
    };

    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(
        !batch.is_finished(),
        "force-settle-batch must wait on money_fx"
    );

    // Quiescence also waits.
    let q = {
        let app = app.clone();
        tokio::spawn(async move {
            app.oneshot(
                Request::builder()
                    .uri("/v1/admin/quiescence")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap()
        })
    };
    tokio::time::sleep(Duration::from_millis(40)).await;
    assert!(!q.is_finished(), "quiescence must wait on money_fx");

    drop(hold);
    let batch_res = tokio::time::timeout(Duration::from_secs(5), batch)
        .await
        .expect("batch should complete")
        .unwrap();
    assert_eq!(batch_res.status(), StatusCode::OK);
    assert_eq!(body_json(batch_res).await["settled_count"], 1);

    let q_res = tokio::time::timeout(Duration::from_secs(5), q)
        .await
        .expect("quiescence should complete")
        .unwrap();
    let qv = body_json(q_res).await;
    // Job settled but outbox may still have entry → ready may be false.
    assert_eq!(qv["active_jobs"], 0);
}

#[tokio::test]
async fn recover_batch_blocks_while_money_fx_held() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-rbx".into()),
            "rbx-1",
            "pilot-account",
            40_000,
            epoch,
        )
        .unwrap();
    }

    let fx = state.money_fx.clone();
    let app = router(state.clone());
    let hold = fx.lock().await;

    let batch = {
        let app = app.clone();
        tokio::spawn(async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/recover-undispatched-batch")
                    .header("content-type", "application/json")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap()
        })
    };

    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(
        !batch.is_finished(),
        "recover-undispatched-batch must wait on money_fx"
    );
    drop(hold);

    let res = tokio::time::timeout(Duration::from_secs(5), batch)
        .await
        .expect("batch should complete")
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["released_count"], 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}
