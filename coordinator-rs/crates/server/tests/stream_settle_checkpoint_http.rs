//! Streaming chat settles only after chunk checkpoint (DECISIONS #49).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::pilot_app_state;
use darkbloom_coordinator::router;
use darkbloom_core::{HealthMachine, ProviderSnapshot, TrustState};
use http_body_util::BodyExt;
use serde_json::json;
use std::collections::HashSet;
use tower::ServiceExt;

#[tokio::test]
async fn stream_chat_settles_after_checkpoint_and_conserves_money() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let outbox = state.outbox.clone();
    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-stream".into(),
            session_epoch: 1,
            trusted: true,
            challenge_fresh: true,
            encrypted_transport: true,
            ready_models: ready,
            health: HealthMachine::healthy(),
            data_lane_full: false,
            predicted_first_content_ms: 10.0,
            predicted_decode_ms: 20.0,
            trust: TrustState::default(),
        })
        .await
        .unwrap();
    tokio::task::yield_now().await;

    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "model": "pilot-text-model",
                        "messages": [{"role":"user","content":"hello stream"}],
                        "stream": true
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ctype = res
        .headers()
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        ctype.contains("text/event-stream"),
        "ctype={ctype}"
    );
    let body = String::from_utf8(res.into_body().collect().await.unwrap().to_bytes().to_vec())
        .unwrap();
    assert!(body.contains("data:"));
    assert!(body.contains("[DONE]"));

    // Mock stream: actual claim 1000µUSD, cap = billable_tokens*10, reserved 100_000.
    // Full pipe accept → charge = min(1000, tokens*10, 100000).
    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 0);
    let bal = led.balance("pilot-account").0;
    assert!(
        bal < 1_000_000 && bal >= 1_000_000 - 100_000,
        "balance={bal} should reflect a stream settle charge"
    );
    let charged = 1_000_000 - bal;
    // Mock provider claims 1000µUSD but stream cap is billable_tokens*10.
    // Full accept of a short echo yields tokens*10 < 1000 → checkpoint clamp wins.
    assert!(
        charged > 0 && charged < 1_000,
        "charged={charged} should be checkpoint-clamped below mock claim 1000"
    );
    drop(led);

    assert_eq!(outbox.lock().await.len(), 1);
    let e = outbox.lock().await.try_claim().unwrap();
    assert_eq!(e.kind, "inference.settled");
    let payload: serde_json::Value = serde_json::from_str(&e.payload).unwrap();
    assert_eq!(payload["charged_micro_usd"], charged);
}
