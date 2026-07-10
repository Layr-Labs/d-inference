//! Admin cancel-inflight wakes chat wait_terminal (DECISIONS #164).

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
use std::time::Duration;
use tokio::sync::{mpsc, Notify};
use tower::ServiceExt;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancel_inflight_aborts_wait_terminal() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let hub = state.hub.clone();
    let cancels = state.job_cancels.clone();

    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-cancel-inf".into(),
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
    let (tx, mut rx) = mpsc::channel(8);
    hub.attach("p-cancel-inf".into(), 1, tx).await;
    let hub2 = hub.clone();
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            let attempt = v["attempt_id"].as_str().unwrap_or("").to_string();
            match v["type"].as_str() {
                Some("prepare") => {
                    hub2.deliver_reply(
                        "p-cancel-inf",
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
                        "p-cancel-inf",
                        &attempt,
                        InboundReply::Started(json!({
                            "type": "started",
                            "attempt_id": attempt,
                            "job_id": v["job_id"],
                            "lease_id": v["lease_id"],
                        })),
                    )
                    .await;
                    started2.notify_one();
                }
                Some("cancel") => {}
                _ => {}
            }
        }
    });

    let app = router(state.clone());
    let bal_before = ledger.lock().await.balance("pilot-account").0;
    let handle = tokio::runtime::Handle::current();
    let chat = std::thread::spawn({
        let app = app.clone();
        move || {
            handle.block_on(async move {
                app.oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/chat/completions")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "model": "pilot-text-model",
                                "messages": [{"role":"user","content":"cancel-me"}],
                                "stream": false
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap()
            })
        }
    });

    started.notified().await;
    // Wait until chat has registered its cancel token.
    let job_id = {
        let mut found = None;
        for _ in 0..100 {
            let led = ledger.lock().await;
            let ids = led.active_job_ids();
            if !ids.is_empty() && cancels.len().await > 0 {
                found = Some(ids[0].clone());
                break;
            }
            drop(led);
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        found.expect("inflight job with cancel token")
    };

    let cancel_res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cancel-inflight")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": job_id }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(cancel_res.status(), StatusCode::OK);
    assert_eq!(body_json(cancel_res).await["action"], "cancel_signaled");

    let chat_res = tokio::task::spawn_blocking(move || chat.join().unwrap())
        .await
        .unwrap();
    assert_eq!(chat_res.status(), StatusCode::NO_CONTENT);
    let v = body_json(chat_res).await;
    assert_eq!(v["cancelled"], true);
    assert!(
        v["outcome"].as_str().unwrap_or("").contains("CancelledAwaitTerminal"),
        "outcome: {}",
        v["outcome"]
    );

    // Funded start: money still held until force-settle / terminal.
    let led = ledger.lock().await;
    assert_eq!(led.held_start_authorized_count(), 1);
    assert_eq!(led.balance("pilot-account").0, bal_before - 100_000);
}
