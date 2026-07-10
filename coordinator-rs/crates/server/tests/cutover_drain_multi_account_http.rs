//! Multi-account + charged cutover-drain (DECISIONS #95).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use tower::ServiceExt;

#[tokio::test]
async fn cutover_drain_multi_account_refunds_each_owner() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("erin", 400_000, 0).unwrap();
        led.credit("frank", 400_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-erin".into()),
            "erin-res",
            "erin",
            30_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-frank".into()),
            "frank-held",
            "frank",
            45_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "frank-held", "frank")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(91)).unwrap();

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cutover_drained");
    assert_eq!(v["ready"], true);
    assert_eq!(v["clear_orphans"]["released_count"], 1);
    assert_eq!(v["clear_orphans"]["settled_count"], 1);
    assert_eq!(state.ledger.lock().await.balance("erin").0, 400_000);
    assert_eq!(state.ledger.lock().await.balance("frank").0, 400_000);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
    assert_eq!(state.outbox.lock().await.pending_under_retry_cap(), 0);
}

#[tokio::test]
async fn cutover_drain_with_actual_charges_held() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-chg-cd".into()),
            "chg-cd-held",
            "pilot-account",
            100_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "chg-cd-held", "pilot-account")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(92)).unwrap();

    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"actual_micro_usd":30000}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["clear_orphans"]["settled_count"], 1);
    assert_eq!(v["clear_orphans"]["charged_micro_usd"], 30_000);
    // 1_000_000 - 100k reserved + (100k - 30k) refund = 970_000
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        970_000
    );
}

#[tokio::test]
async fn cutover_drain_account_filter_leaves_foreign_jobs() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("gina", 200_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-gina".into()),
            "gina-res",
            "gina",
            20_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-pilot-cd".into()),
            "pilot-cd-res",
            "pilot-account",
            15_000,
            epoch0,
        )
        .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(93)).unwrap();

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"account":"pilot-account"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    // Foreign gina job remains → not ready.
    assert_eq!(v["ready"], false);
    assert_eq!(v["active_jobs"], 1);
    assert_eq!(v["clear_orphans"]["released_count"], 1);
    assert_eq!(state.ledger.lock().await.balance("gina").0, 180_000);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );

    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        body_json(res).await["cutover_hint"],
        "adopt-jobs then cutover-drain-all"
    );
}
