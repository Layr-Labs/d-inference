//! One-shot clear-orphans: adopt → recover → force-settle (DECISIONS #79).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use tower::ServiceExt;

#[tokio::test]
async fn clear_orphans_one_shot_clears_mixed() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (id, amt, hold) in [
            ("co-res", 30_000, false),
            ("co-held", 45_000, true),
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
    state.ownership.acquire(Epoch(99)).unwrap();

    let app = router(state.clone());
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
    assert_eq!(v["action"], "cleared_orphans");
    assert_eq!(v["adopted_count"], 2);
    assert_eq!(v["released_count"], 1);
    assert_eq!(v["settled_count"], 1);
    assert_eq!(v["refunded_micro_usd"], 30_000);
    assert_eq!(v["charged_micro_usd"], 0);
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(v["held_start_authorized"], 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
}

#[tokio::test]
async fn clear_orphans_rejects_without_ownership() {
    let state = pilot_app_state(false);
    let app = router(state);
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
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
}
