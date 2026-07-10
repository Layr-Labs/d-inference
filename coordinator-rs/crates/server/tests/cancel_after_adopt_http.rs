//! Cancel-attempt after adopt still holds money (DECISIONS #66/#68).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn cancel_attempt_after_adopt_holds_money() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;

    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-ca-adopt".into()),
            "held-ca",
            "pilot-account",
            120_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "held-ca", "pilot-account")
            .unwrap();
    }

    state.ownership.release();
    state.ownership.acquire(Epoch(12)).unwrap();

    let app = router(state.clone());
    let bal_before = state.ledger.lock().await.balance("pilot-account").0;

    // Adopt then cancel — money stays held.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-job")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "held-ca" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cancel-attempt")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "held-ca",
                        "attempt_id": "a1",
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
    assert_eq!(v["action"], "cancelled_await_terminal");
    assert_eq!(v["held_start_authorized"], 1);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        bal_before
    );
}
