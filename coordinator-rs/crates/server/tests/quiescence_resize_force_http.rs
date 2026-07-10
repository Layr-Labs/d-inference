//! HTTP: quiescence held after resize_and_authorize; force_settle clears.

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, OperationKey};
use tower::ServiceExt;

fn test_state() -> darkbloom_coordinator::AppState {
    pilot_app_state(true)
}

#[tokio::test]
async fn quiescence_held_after_resize_then_cleared_by_force_settle() {
    let state = test_state();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(OperationKey("r".into()), "held-ra", "pilot-account", 100_000)
            .unwrap();
        led.resize_and_authorize(OperationKey("ra".into()), "held-ra", "pilot-account", 250_000)
            .unwrap();
    }
    let app = router(state.clone());
    let q1 = app
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
    assert_eq!(q1.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v1 = body_json(q1).await;
    assert_eq!(v1["held_start_authorized"], 1);
    assert_eq!(v1["held_start_authorized_job_ids"][0], "held-ra");

    {
        let mut led = state.ledger.lock().await;
        assert!(led
            .settle_capped_as(
                OperationKey("force_settle:held-ra".into()),
                "held-ra",
                "pilot-account",
                80_000,
                250_000,
                "force-ra-d",
                "force_settled",
            )
            .unwrap());
    }

    let q2 = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q2.status(), StatusCode::OK);
    let v2 = body_json(q2).await;
    assert_eq!(v2["ready"], true);
    assert_eq!(v2["held_start_authorized"], 0);
    assert_eq!(v2["active_jobs"], 0);
}
