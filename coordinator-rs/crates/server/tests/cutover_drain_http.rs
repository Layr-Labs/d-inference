//! held-review-batch + cutover-drain one-shot (DECISIONS #91).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use tower::ServiceExt;

#[tokio::test]
async fn held_review_batch_classifies_without_money_move() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-hrb".into()),
            "hrb-held",
            "pilot-account",
            40_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "hrb-held", "pilot-account")
            .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-hrb2".into()),
            "hrb-res",
            "pilot-account",
            10_000,
            epoch,
        )
        .unwrap();
    }
    let bal_before = state.ledger.lock().await.balance("pilot-account").0;
    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review-batch")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "held_review_batch");
    assert_eq!(v["held_for_review_count"], 1);
    assert_eq!(v["skipped_count"], 0);
    assert_eq!(v["reviews"][0]["job_id"], "hrb-held");
    assert_eq!(v["reviews"][0]["action"], "held_for_review");
    // Explicit reserved id is skipped (not held).
    let res = router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review-batch")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"job_ids":["hrb-res","hrb-held"]}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    let v = body_json(res).await;
    assert_eq!(v["held_for_review_count"], 1);
    assert_eq!(v["skipped_count"], 1);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        bal_before
    );
    assert_eq!(state.ledger.lock().await.active_job_count(), 2);
}

#[tokio::test]
async fn cutover_drain_clears_orphans_and_makes_ready() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cd".into()),
            "cd-res",
            "pilot-account",
            25_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cd-h".into()),
            "cd-held",
            "pilot-account",
            35_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "cd-held", "pilot-account")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(44)).unwrap();

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
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(v["clear_orphans"]["released_count"], 1);
    assert_eq!(v["clear_orphans"]["settled_count"], 1);
    assert!(v["outbox_drain"]["acked_count"].as_u64().unwrap() >= 2);

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
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["cutover_hint"], "ready");
}

#[tokio::test]
async fn cutover_drain_rejects_without_ownership() {
    let state = pilot_app_state(false);
    let app = router(state);
    let res = app
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
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
}
