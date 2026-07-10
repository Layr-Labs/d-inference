//! Ownership steal during live prepare leaves reserved job for adopt+recover
//! (DECISIONS #67).

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
async fn live_prepare_aborts_on_ownership_steal_holds_reserved() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let outbox = state.outbox.clone();
    let ownership = state.ownership.clone();
    let hub = state.hub.clone();

    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-prep-steal".into(),
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

    let saw_prepare = Arc::new(Notify::new());
    let saw_prepare2 = saw_prepare.clone();

    let (tx, mut rx) = mpsc::channel(8);
    hub.attach("p-prep-steal".into(), 1, tx).await;
    // Never reply to prepare — ownership steal should abort the wait.
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            if v["type"].as_str() == Some("prepare") {
                saw_prepare2.notify_one();
            }
            // Intentionally no Prepared reply.
            let _ = (v, InboundReply::Prepared(json!({})));
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
                        "messages": [{"role":"user","content":"prep steal"}],
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
        saw_prepare.notified().await;
        ownership.release();
    };
    let (res, _) = tokio::join!(req_fut, steal_fut);

    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");

    let led = ledger.lock().await;
    // Reserved but not start_authorized — active job, not held_start_authorized.
    assert_eq!(led.active_job_count(), 1);
    assert_eq!(led.held_start_authorized_count(), 0);
    assert_eq!(led.balance("pilot-account").0, bal_before - 100_000);
    drop(led);
    assert_eq!(outbox.lock().await.len(), 0);
}
