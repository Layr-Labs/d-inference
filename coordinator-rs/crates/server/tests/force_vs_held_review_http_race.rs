//! Concurrent HTTP force-settle vs held-review: force clears; review never moves money.

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
async fn concurrent_http_force_settle_vs_held_review() {
    let state = test_state();
    let ledger = state.ledger.clone();
    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-fhr".into()),
            "held-fhr",
            "pilot-account",
            200_000,
        )
        .unwrap();
        led.mark_start_authorized("held-fhr", "pilot-account")
            .unwrap();
    }
    let app = router(state);

    let app_f = app.clone();
    let force = tokio::spawn(async move {
        let res = app_f
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/force-settle")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "job_id": "held-fhr",
                            "actual_micro_usd": 50_000,
                            "terminal_digest": "fhr-d"
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        body_json(res).await["action"].as_str().unwrap().to_string()
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
                        .body(Body::from(json!({ "job_id": "held-fhr" }).to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["action"].as_str().unwrap().to_string()
        }));
    }

    assert_eq!(force.await.unwrap(), "released");
    for h in reviews {
        match h.await.unwrap().as_str() {
            "held_for_review" | "already_terminal" => {}
            other => panic!("unexpected review action {other}"),
        }
    }

    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 0);
    assert_eq!(led.held_start_authorized_count(), 0);
    // 1M - 200k + 150k refund = 950k
    assert_eq!(led.balance("pilot-account").0, 950_000);
    assert_eq!(led.job_disposition("held-fhr"), Some("force_settled"));
}
