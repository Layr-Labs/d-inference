//! Concurrent HTTP recover-undispatched: exactly one released + one outbox.

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
async fn concurrent_http_recover_undispatched_exactly_one_released() {
    let state = test_state();
    let outbox = state.outbox.clone();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-cru".into()),
            "undisp-cru",
            "pilot-account",
            120_000,
        )
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
                        .uri("/v1/admin/recover-undispatched")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({ "job_id": "undisp-cru" }).to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
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

    // Exactly one critical release side effect (DECISIONS #43).
    assert_eq!(outbox.lock().await.len(), 1);
    let e = outbox.lock().await.try_claim().unwrap();
    assert_eq!(e.kind, "inference.released");
    let payload: serde_json::Value = serde_json::from_str(&e.payload).unwrap();
    assert_eq!(payload["refunded_micro_usd"], 120_000);
}
