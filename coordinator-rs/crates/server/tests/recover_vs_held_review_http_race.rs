//! Concurrent HTTP recover-undispatched vs held-review on start_authorized job.

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
async fn concurrent_http_recover_vs_held_review_never_releases_authorized() {
    let state = test_state();
    let ledger = state.ledger.clone();
    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-rh".into()),
            "held-rh",
            "pilot-account",
            140_000,
        )
        .unwrap();
        led.mark_start_authorized("held-rh", "pilot-account").unwrap();
    }
    let app = router(state);

    let mut recovers = Vec::new();
    for _ in 0..4 {
        let app = app.clone();
        recovers.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/recover-undispatched")
                        .header("content-type", "application/json")
                        .body(Body::from(json!({ "job_id": "held-rh" }).to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["action"].as_str().unwrap().to_string()
        }));
    }
    let mut reviews = Vec::new();
    for _ in 0..4 {
        let app = app.clone();
        reviews.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/held-review")
                        .header("content-type", "application/json")
                        .body(Body::from(json!({ "job_id": "held-rh" }).to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["action"].as_str().unwrap().to_string()
        }));
    }

    for h in recovers {
        assert_eq!(h.await.unwrap(), "skipped");
    }
    for h in reviews {
        assert_eq!(h.await.unwrap(), "held_for_review");
    }

    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 1);
    assert_eq!(led.held_start_authorized_count(), 1);
    assert_eq!(led.balance("pilot-account").0, 860_000);
    assert!(led.job_disposition("held-rh").is_none());
}
