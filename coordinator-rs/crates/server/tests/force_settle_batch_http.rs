//! adopt + recover-batch + force-settle-batch clears mixed orphans (DECISIONS #78).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use tower::ServiceExt;

#[tokio::test]
async fn adopt_then_recover_and_force_settle_batches_clear_mixed_orphans() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (id, amt, hold) in [
            ("mix-res-a", 40_000, false),
            ("mix-res-b", 50_000, false),
            ("mix-held-a", 70_000, true),
            ("mix-held-b", 90_000, true),
        ] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                amt,
                epoch0,
            )
            .unwrap();
            if hold {
                led.mark_start_authorized_fenced(epoch0, id, "pilot-account")
                    .unwrap();
            }
        }
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(88)).unwrap();

    let app = router(state.clone());

    // Quiescence should flag needs_adopt.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let q = body_json(res).await;
    assert_eq!(q["active_jobs"], 4);
    assert!(q["active_jobs_detail"]
        .as_array()
        .unwrap()
        .iter()
        .all(|r| r["needs_adopt"] == true));

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["adopted_count"], 4);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched-batch")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    let v = body_json(res).await;
    assert_eq!(v["released_count"], 2);
    assert_eq!(v["refunded_micro_usd"], 90_000);
    assert_eq!(v["active_jobs"], 2);

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle-batch")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "force_settled_batch");
    assert_eq!(v["settled_count"], 2);
    assert_eq!(v["charged_micro_usd"], 0); // default full refund
    assert_eq!(v["held_start_authorized"], 0);
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
}

#[tokio::test]
async fn force_settle_batch_rejects_negative_actual() {
    let state = pilot_app_state(true);
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle-batch")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"actual_micro_usd":-1}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}
