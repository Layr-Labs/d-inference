//! clear-orphans refunds each job to its own account (DECISIONS #88).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use tower::ServiceExt;

#[tokio::test]
async fn clear_orphans_multi_account_refunds_each_owner() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("alice", 500_000, 0).unwrap();
        led.credit("bob", 500_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-alice".into()),
            "alice-res",
            "alice",
            40_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-bob".into()),
            "bob-held",
            "bob",
            60_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "bob-held", "bob")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(21)).unwrap();

    let app = router(state.clone());
    // Wrong filter leaves foreign jobs untouched.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/clear-orphans")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"account":"pilot-account"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["adopted_count"], 0);
    assert_eq!(v["released_count"], 0);
    assert_eq!(v["settled_count"], 0);
    assert_eq!(state.ledger.lock().await.active_job_count(), 2);

    // No filter: clear both accounts.
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/clear-orphans")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["released_count"], 1);
    assert_eq!(v["settled_count"], 1);
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(state.ledger.lock().await.balance("alice").0, 500_000);
    assert_eq!(state.ledger.lock().await.balance("bob").0, 500_000);
    // Pilot untouched.
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
}
