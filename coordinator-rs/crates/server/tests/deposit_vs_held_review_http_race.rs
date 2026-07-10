//! Concurrent HTTP deposit vs held-review: deposit applies; review never moves money.

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
async fn concurrent_http_deposit_vs_held_review_never_moves_job_money() {
    let state = test_state();
    let ledger = state.ledger.clone();
    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-dhr".into()),
            "held-dhr",
            "pilot-account",
            180_000,
        )
        .unwrap();
        led.mark_start_authorized("held-dhr", "pilot-account")
            .unwrap();
    }
    let app = router(state);

    let app_d = app.clone();
    let deposit = tokio::spawn(async move {
        let res = app_d
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/deposits")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "event_id": "evt_dhr",
                            "amount_micro_usd": 40_000,
                            "withdrawable_micro_usd": 0
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        body_json(res).await["applied"].as_bool().unwrap()
    });

    let mut reviews = Vec::new();
    for _ in 0..8 {
        let app = app.clone();
        reviews.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/held-review")
                        .header("content-type", "application/json")
                        .body(Body::from(json!({ "job_id": "held-dhr" }).to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["action"].as_str().unwrap().to_string()
        }));
    }

    assert!(deposit.await.unwrap());
    for h in reviews {
        assert_eq!(h.await.unwrap(), "held_for_review");
    }

    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 1);
    assert_eq!(led.held_start_authorized_count(), 1);
    // 1M - 180k reserved + 40k deposit = 860k
    assert_eq!(led.balance("pilot-account").0, 860_000);
    assert!(led.job_disposition("held-dhr").is_none());
}
