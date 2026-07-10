//! Concurrent cancel-attempt on the same held job — all await_terminal, no money move
//! (DECISIONS #68).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn concurrent_cancel_attempt_all_await_terminal_no_money_move() {
    let state = pilot_app_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-cancel-race".into()),
            "held-cr",
            "pilot-account",
            180_000,
        )
        .unwrap();
        led.mark_start_authorized("held-cr", "pilot-account")
            .unwrap();
    }
    let bal_before = state.ledger.lock().await.balance("pilot-account").0;
    let app = router(state.clone());

    let mut handles = Vec::new();
    for i in 0..8 {
        let app = app.clone();
        handles.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/cancel-attempt")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "job_id": "held-cr",
                                "attempt_id": format!("a{i}"),
                                "lease_id": "l1",
                                "provider_id": "p-missing"
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            let v = body_json(res).await;
            v["action"] == "cancelled_await_terminal"
        }));
    }

    for h in handles {
        assert!(h.await.unwrap());
    }

    let led = state.ledger.lock().await;
    assert_eq!(led.held_start_authorized_count(), 1);
    assert_eq!(led.balance("pilot-account").0, bal_before);
    assert_eq!(state.outbox.lock().await.len(), 0);
}
