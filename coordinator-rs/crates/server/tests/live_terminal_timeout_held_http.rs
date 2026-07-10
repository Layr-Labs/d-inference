//! Live start succeeds but provider disconnects before terminal → reservation held
//! (DECISIONS #16/#44).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use darkbloom_coordinator::{InboundReply, OutboundCmd};
use darkbloom_core::{HealthMachine, ProviderSnapshot, TrustState};
use serde_json::json;
use std::collections::HashSet;
use std::sync::Arc;
use tokio::sync::mpsc;
use tower::ServiceExt;

#[tokio::test]
async fn live_terminal_disconnect_holds_reservation() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let hub = state.hub.clone();

    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-term-dc".into(),
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
    hub.attach("p-term-dc".into(), 1, tx).await;
    let hub2 = hub.clone();
    let hub_detach = hub.clone();
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            let attempt = v["attempt_id"].as_str().unwrap_or("").to_string();
            match v["type"].as_str() {
                Some("prepare") => {
                    hub2.deliver_reply(
                        "p-term-dc",
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
                        "p-term-dc",
                        &attempt,
                        InboundReply::Started(json!({
                            "type": "started",
                            "attempt_id": attempt,
                            "job_id": v["job_id"],
                            "lease_id": v["lease_id"],
                        })),
                    )
                    .await;
                    // Drop the provider before terminal arrives so wait_terminal fails.
                    hub_detach.detach("p-term-dc", 1).await;
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
    // Disconnected / timeout both map to terminal-timeout held.
    assert_eq!(res.status(), StatusCode::GATEWAY_TIMEOUT);
    assert_eq!(
        body_json(res).await["error"]["code"],
        "provider_terminal_timeout_held"
    );

    let led = ledger.lock().await;
    assert_eq!(led.held_start_authorized_count(), 1);
    assert_eq!(led.balance("pilot-account").0, 900_000);
}
