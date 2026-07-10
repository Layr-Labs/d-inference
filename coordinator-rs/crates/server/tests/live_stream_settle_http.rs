//! Live streaming settle after checkpoint (DECISIONS #44/#48/#49).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::pilot_app_state;
use darkbloom_coordinator::router;
use darkbloom_coordinator::{InboundReply, OutboundCmd};
use darkbloom_core::{HealthMachine, ProviderSnapshot, TrustState};
use http_body_util::BodyExt;
use serde_json::json;
use std::collections::HashSet;
use tokio::sync::mpsc;
use tower::ServiceExt;

#[tokio::test]
async fn live_stream_settles_after_checkpoint_clamp() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let outbox = state.outbox.clone();
    let hub = state.hub.clone();

    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-live-stream".into(),
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

    let (tx, mut rx) = mpsc::channel(8);
    hub.attach("p-live-stream".into(), 1, tx).await;
    let hub2 = hub.clone();
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            let attempt = v["attempt_id"].as_str().unwrap_or("").to_string();
            match v["type"].as_str() {
                Some("prepare") => {
                    hub2.deliver_reply(
                        "p-live-stream",
                        &attempt,
                        InboundReply::Prepared(json!({
                            "type": "prepared",
                            "attempt_id": attempt,
                            "lease_ttl_ms": 15000,
                            "prompt_tokens": 1,
                            "max_output_tokens": 8,
                            "engine_queue_depth": 0,
                            "prefill_can_begin": true
                        })),
                    )
                    .await;
                }
                Some("start") => {
                    hub2.deliver_reply(
                        "p-live-stream",
                        &attempt,
                        InboundReply::Started(json!({
                            "type": "started",
                            "attempt_id": attempt,
                            "job_id": v["job_id"],
                            "lease_id": v["lease_id"],
                        })),
                    )
                    .await;
                    // Inflated completion_tokens — stream checkpoint must clamp charge.
                    hub2.deliver_reply(
                        "p-live-stream",
                        &attempt,
                        InboundReply::Terminal(json!({
                            "type": "provider_terminal",
                            "job_id": v["job_id"],
                            "attempt_id": attempt,
                            "lease_id": v["lease_id"],
                            "coordinator_epoch": v["coordinator_epoch"],
                            "dispatch_nonce": v["dispatch_nonce"],
                            "request_digest": v["request_digest"],
                            "terminal_digest": "sha256:live-stream",
                            "prompt_tokens": 1,
                            "completion_tokens": 500,
                            "outcome": "completed"
                        })),
                    )
                    .await;
                }
                _ => {}
            }
        }
    });

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
                        "messages": [{"role":"user","content":"stream me"}],
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
    assert!(ctype.contains("text/event-stream"), "ctype={ctype}");
    let body = String::from_utf8(res.into_body().collect().await.unwrap().to_bytes().to_vec())
        .unwrap();
    assert!(body.contains("[DONE]"));

    // Provider claimed 500 tokens * 10 = 5000µUSD, but stream content is short so
    // checkpoint billable_tokens*10 << 5000 → clamp wins.
    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 0);
    let bal = led.balance("pilot-account").0;
    let charged = 1_000_000 - bal;
    assert!(
        charged > 0 && charged < 5_000,
        "charged={charged} should be checkpoint-clamped below inflated claim"
    );
    drop(led);

    let e = outbox.lock().await.try_claim().unwrap();
    assert_eq!(e.kind, "inference.settled");
    let payload: serde_json::Value = serde_json::from_str(&e.payload).unwrap();
    assert_eq!(payload["charged_micro_usd"], charged);
    assert_eq!(payload["terminal_digest"], "sha256:live-stream");
}
