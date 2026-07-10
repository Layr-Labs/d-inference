//! Concurrent HTTP force-settle: exactly one released; others already_terminal.

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
async fn concurrent_http_force_settle_exactly_one_released() {
    let state = test_state();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-cfs".into()),
            "held-cfs",
            "pilot-account",
            200_000,
        )
        .unwrap();
        led.mark_start_authorized("held-cfs", "pilot-account")
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
                        .uri("/v1/admin/force-settle")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "job_id": "held-cfs",
                                "actual_micro_usd": 40_000,
                                "terminal_digest": "cfs-shared-d"
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            // Same op key + same digest: first Released, rest AlreadyTerminal (200).
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["action"].as_str().unwrap().to_string()
        }));
    }

    let mut released = 0usize;
    let mut terminal = 0usize;
    for h in handles {
        match h.await.unwrap().as_str() {
            "released" => released += 1,
            "already_terminal" => terminal += 1,
            other => panic!("unexpected action {other}"),
        }
    }
    assert_eq!(released, 1);
    assert_eq!(terminal, 7);
}
