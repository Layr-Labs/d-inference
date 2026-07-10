//! Concurrent HTTP held-review: never moves money.

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

fn test_state() -> darkbloom_coordinator::AppState {
    pilot_app_state(true)
}

#[tokio::test]
async fn concurrent_http_held_review_never_moves_money() {
    let state = test_state();
    let ledger = state.ledger.clone();
    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-chr".into()),
            "held-chr",
            "pilot-account",
            180_000,
        )
        .unwrap();
        led.mark_start_authorized("held-chr", "pilot-account")
            .unwrap();
    }
    let app = router(state);
    let mut handles = Vec::new();
    for _ in 0..8 {
        let app = app.clone();
        handles.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/held-review")
                        .header("content-type", "application/json")
                        .body(Body::from(json!({ "job_id": "held-chr" }).to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            let v = body_json(res).await;
            assert_eq!(v["action"], "held_for_review");
            v["balance_micro_usd"].as_i64().unwrap()
        }));
    }

    for h in handles {
        assert_eq!(h.await.unwrap(), 820_000);
    }
    let led = ledger.lock().await;
    assert_eq!(led.balance("pilot-account").0, 820_000);
    assert_eq!(led.held_start_authorized_count(), 1);
    assert_eq!(led.active_job_count(), 1);
}
