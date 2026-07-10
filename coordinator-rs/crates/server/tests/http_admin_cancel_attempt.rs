//! Admin cancel-attempt for start_authorized jobs (DECISIONS #68).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use darkbloom_coordinator::{InboundReply, OutboundCmd};
use serde_json::json;
use tokio::sync::mpsc;
use tower::ServiceExt;

#[tokio::test]
async fn admin_cancel_attempt_skips_reserved_not_authorized() {
    let state = pilot_app_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-cancel-skip".into()),
            "res-only",
            "pilot-account",
            100_000,
        )
        .unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cancel-attempt")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "res-only",
                        "attempt_id": "a1",
                        "lease_id": "l1",
                        "provider_id": "p1"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["action"], "skipped");
}

#[tokio::test]
async fn admin_cancel_attempt_sends_cancel_and_holds_money() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let outbox = state.outbox.clone();
    let hub = state.hub.clone();

    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-cancel-hold".into()),
            "held-cancel",
            "pilot-account",
            150_000,
        )
        .unwrap();
        led.mark_start_authorized("held-cancel", "pilot-account")
            .unwrap();
    }

    let (tx, mut rx) = mpsc::channel(8);
    hub.attach("p-cancel".into(), 1, tx).await;
    let hub2 = hub.clone();
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            let attempt = v["attempt_id"].as_str().unwrap_or("").to_string();
            if v["type"].as_str() == Some("cancel") || v["type"].as_str() == Some("abort") {
                hub2.deliver_reply(
                    "p-cancel",
                    &attempt,
                    InboundReply::Cancelled(json!({
                        "type": "cancelled",
                        "attempt_id": attempt
                    })),
                )
                .await;
            }
        }
    });

    let bal_before = ledger.lock().await.balance("pilot-account").0;
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cancel-attempt")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "held-cancel",
                        "attempt_id": "a-cancel",
                        "lease_id": "l-cancel",
                        "provider_id": "p-cancel",
                        "dispatch_nonce": "n1",
                        "request_digest": "sha256:req"
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
    assert_eq!(v["reserved_micro_usd"], 150_000);

    // Money still held — no release outbox.
    assert_eq!(ledger.lock().await.balance("pilot-account").0, bal_before);
    assert_eq!(outbox.lock().await.len(), 0);
}

#[tokio::test]
async fn admin_cancel_attempt_rejects_empty_fields() {
    let app = router(pilot_app_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cancel-attempt")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "j",
                        "attempt_id": "",
                        "lease_id": "l",
                        "provider_id": "p"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    assert_eq!(body_json(res).await["error"]["code"], "invalid_cancel_attempt");
}

#[tokio::test]
async fn admin_cancel_attempt_without_ownership_returns_503() {
    let state = pilot_app_state(false);
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cancel-attempt")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "j",
                        "attempt_id": "a",
                        "lease_id": "l",
                        "provider_id": "p"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn admin_adopt_job_rejects_disposed() {
    let state = pilot_app_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-disp".into()),
            "disposed-1",
            "pilot-account",
            50_000,
        )
        .unwrap();
        led.release(
            darkbloom_coordinator::OperationKey("rel-disp".into()),
            "disposed-1",
            "pilot-account",
        )
        .unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-job")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "disposed-1" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT);
    assert_eq!(body_json(res).await["error"]["code"], "adopt_job_failed");
}
