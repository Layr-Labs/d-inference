//! Invalid live provider_terminal leaves reservation held (DECISIONS #48).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use darkbloom_coordinator::{InboundReply, OutboundCmd};
use darkbloom_core::{HealthMachine, ProviderSnapshot, TrustState};
use serde_json::json;
use std::collections::HashSet;
use tokio::sync::mpsc;
use tower::ServiceExt;

#[tokio::test]
async fn live_terminal_job_mismatch_holds_reservation() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let hub = state.hub.clone();

    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-bad-term".into(),
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
    hub.attach("p-bad-term".into(), 1, tx).await;
    let hub2 = hub.clone();
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            let attempt = v["attempt_id"].as_str().unwrap_or("").to_string();
            match v["type"].as_str() {
                Some("prepare") => {
                    hub2.deliver_reply(
                        "p-bad-term",
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
                        "p-bad-term",
                        &attempt,
                        InboundReply::Started(json!({
                            "type": "started",
                            "attempt_id": attempt,
                            "job_id": v["job_id"],
                            "lease_id": v["lease_id"],
                        })),
                    )
                    .await;
                    // Deliberately wrong job_id → validate_provider_terminal fails.
                    hub2.deliver_reply(
                        "p-bad-term",
                        &attempt,
                        InboundReply::Terminal(json!({
                            "type": "provider_terminal",
                            "job_id": "job-attacker",
                            "attempt_id": attempt,
                            "lease_id": v["lease_id"],
                            "coordinator_epoch": v["coordinator_epoch"],
                            "dispatch_nonce": v["dispatch_nonce"],
                            "request_digest": v["request_digest"],
                            "terminal_digest": "sha256:bad",
                            "prompt_tokens": 1,
                            "completion_tokens": 1,
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
                        "messages": [{"role":"user","content":"x"}],
                        "stream": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_GATEWAY);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "provider_terminal_invalid_held");

    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 1);
    assert_eq!(led.held_start_authorized_count(), 1);
    // Reservation still held — balance remains debited.
    assert_eq!(led.balance("pilot-account").0, 900_000);
}
