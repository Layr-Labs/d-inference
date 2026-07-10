//! Valid live provider_terminal settles and conserves money (DECISIONS #44/#48).

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
async fn live_terminal_valid_settles_and_conserves() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let outbox = state.outbox.clone();
    let terminals = state.terminals.clone();
    let hub = state.hub.clone();

    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-ok-term".into(),
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
    hub.attach("p-ok-term".into(), 1, tx).await;
    let hub2 = hub.clone();
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            let attempt = v["attempt_id"].as_str().unwrap_or("").to_string();
            match v["type"].as_str() {
                Some("prepare") => {
                    hub2.deliver_reply(
                        "p-ok-term",
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
                        "p-ok-term",
                        &attempt,
                        InboundReply::Started(json!({
                            "type": "started",
                            "attempt_id": attempt,
                            "job_id": v["job_id"],
                            "lease_id": v["lease_id"],
                        })),
                    )
                    .await;
                    hub2.deliver_reply(
                        "p-ok-term",
                        &attempt,
                        InboundReply::Terminal(json!({
                            "type": "provider_terminal",
                            "job_id": v["job_id"],
                            "attempt_id": attempt,
                            "lease_id": v["lease_id"],
                            "coordinator_epoch": v["coordinator_epoch"],
                            "dispatch_nonce": v["dispatch_nonce"],
                            "request_digest": v["request_digest"],
                            "terminal_digest": "sha256:live-ok",
                            "se_signature": "se-sig-live-ok",
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
    let res = app
        .oneshot(
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
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["object"], "chat.completion");
    // 5 completion tokens * 10 µUSD = 50 charged from 100_000 reserve.
    assert_eq!(v["darkbloom"]["charged_micro_usd"], 50);
    assert_eq!(v["darkbloom"]["terminal_digest"], "sha256:live-ok");
    assert_eq!(v["darkbloom"]["mode"], "rust-live");

    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 0);
    assert_eq!(led.held_start_authorized_count(), 0);
    // 1_000_000 - 50 charged = 999_950
    assert_eq!(led.balance("pilot-account").0, 999_950);
    drop(led);

    assert_eq!(outbox.lock().await.len(), 1);
    let e = outbox.lock().await.try_claim().unwrap();
    assert_eq!(e.kind, "inference.settled");
    let payload: serde_json::Value = serde_json::from_str(&e.payload).unwrap();
    assert_eq!(payload["charged_micro_usd"], 50);
    assert_eq!(payload["terminal_digest"], "sha256:live-ok");

    // SE signature persisted on disposition (DECISIONS #57) — wrong sig conflicts.
    let mut terms = terminals.lock().await;
    let ack = darkbloom_coordinator::ingest_terminal(
        &mut terms,
        darkbloom_coordinator::TerminalIngest {
            job_id: String::new(),
            attempt_id: "any".into(),
            terminal_digest: "sha256:live-ok".into(),
            lease_id: String::new(),
            se_signature: "se-sig-attacker".into(),
            outcome: String::new(),
        },
    )
    .unwrap();
    assert_eq!(ack["disposition"], "conflict");
    let ack_ok = darkbloom_coordinator::ingest_terminal(
        &mut terms,
        darkbloom_coordinator::TerminalIngest {
            job_id: String::new(),
            attempt_id: "any".into(),
            terminal_digest: "sha256:live-ok".into(),
            lease_id: String::new(),
            se_signature: "se-sig-live-ok".into(),
            outcome: String::new(),
        },
    )
    .unwrap();
    assert_eq!(ack_ok["disposition"], "settled");
}
