//! After live start, ownership steal before settle holds the reservation
//! (DECISIONS #47/#52) — never charges after fencing loss.

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
use tokio::sync::{mpsc, Notify};
use tower::ServiceExt;

#[tokio::test]
async fn live_settle_after_ownership_steal_holds_reservation() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let ownership = state.ownership.clone();
    let hub = state.hub.clone();

    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-own-steal".into(),
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

    let started = Arc::new(Notify::new());
    let started2 = started.clone();
    let release_gate = Arc::new(Notify::new());
    let release_gate2 = release_gate.clone();

    let (tx, mut rx) = mpsc::channel(8);
    hub.attach("p-own-steal".into(), 1, tx).await;
    let hub2 = hub.clone();
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            let attempt = v["attempt_id"].as_str().unwrap_or("").to_string();
            match v["type"].as_str() {
                Some("prepare") => {
                    hub2.deliver_reply(
                        "p-own-steal",
                        &attempt,
                        InboundReply::Prepared(json!({
                            "type": "prepared",
                            "attempt_id": attempt,
                            "lease_ttl_ms": 15000,
                            "prompt_tokens": 2,
                            "max_output_tokens": 8,
                            "engine_queue_depth": 0,
                            "prefill_can_begin": true
                        })),
                    )
                    .await;
                }
                Some("start") => {
                    hub2.deliver_reply(
                        "p-own-steal",
                        &attempt,
                        InboundReply::Started(json!({
                            "type": "started",
                            "attempt_id": attempt,
                            "job_id": v["job_id"],
                            "lease_id": v["lease_id"],
                        })),
                    )
                    .await;
                    // Signal that start landed; wait for ownership steal, then terminal.
                    started2.notify_one();
                    release_gate2.notified().await;
                    hub2.deliver_reply(
                        "p-own-steal",
                        &attempt,
                        InboundReply::Terminal(json!({
                            "type": "provider_terminal",
                            "job_id": v["job_id"],
                            "attempt_id": attempt,
                            "lease_id": v["lease_id"],
                            "coordinator_epoch": v["coordinator_epoch"],
                            "dispatch_nonce": v["dispatch_nonce"],
                            "request_digest": v["request_digest"],
                            "terminal_digest": "sha256:own-steal",
                            "prompt_tokens": 2,
                            "completion_tokens": 5,
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
    let bal_before = ledger.lock().await.balance("pilot-account").0;
    let req_fut = async {
        app.oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "model": "pilot-text-model",
                        "messages": [{"role":"user","content":"hi"}],
                        "stream": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap()
    };
    let steal_fut = async {
        started.notified().await;
        ownership.release();
        release_gate.notify_one();
    };
    let (res, _) = tokio::join!(req_fut, steal_fut);

    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "ownership_lost");

    let led = ledger.lock().await;
    assert_eq!(led.held_start_authorized_count(), 1);
    assert_eq!(led.balance("pilot-account").0, bal_before - 100_000);
}
