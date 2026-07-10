//! Axum integration: admin deposits + ownership fencing on chat.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use darkbloom_coordinator::{
    bounded_telemetry, router, spawn_fleet_actor, AppState, CoordinatorKeys, Epoch,
    ExternalEventInbox, MemoryLedger, MemoryTerminalStore, ModelCard, Outbox, OwnershipGate,
    ProviderHub,
};
use darkbloom_core::PlacementController;
use http_body_util::BodyExt;
use serde_json::json;
use std::sync::Arc;
use tokio::sync::Mutex;
use tower::ServiceExt;

fn test_state(holding: bool) -> AppState {
    let (fleet, _) = spawn_fleet_actor();
    let ownership = Arc::new(OwnershipGate::new(false));
    if holding {
        ownership.acquire(Epoch(9)).unwrap();
    }
    let (telemetry, _worker) = bounded_telemetry(16);
    let mut ledger = MemoryLedger::default();
    ledger.credit("pilot-account", 1_000_000, 0).unwrap();
    AppState {
        fleet,
        hub: ProviderHub::new(),
        keys: CoordinatorKeys::generate("test"),
        models: vec![ModelCard {
            id: "pilot-text-model".into(),
            object: "model".into(),
            owned_by: "darkbloom".into(),
        }],
        ledger: Arc::new(Mutex::new(ledger)),
        placement: Arc::new(Mutex::new(PlacementController::default())),
        telemetry: Arc::new(telemetry),
        pilot_account: "pilot-account".into(),
        pilot_api_keys: Arc::new(vec![]),
        coordinator_epoch: 9,
        ownership,
        external_events: Arc::new(Mutex::new(ExternalEventInbox::new())),
        outbox: Arc::new(Mutex::new(Outbox::default())),
        terminals: Arc::new(Mutex::new(MemoryTerminalStore::new())),
    }
}

async fn body_json(res: axum::response::Response) -> serde_json::Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn admin_deposit_applies_then_replays() {
    let state = test_state(true);
    let outbox = state.outbox.clone();
    let app = router(state);
    let req = Request::builder()
        .method("POST")
        .uri("/v1/admin/deposits")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "event_id": "evt_it_1",
                "amount_micro_usd": 250_000,
                "withdrawable_micro_usd": 100_000
            })
            .to_string(),
        ))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["applied"], true);
    assert_eq!(v["balance_micro_usd"], 1_250_000);
    assert_eq!(outbox.lock().await.len(), 1);

    let req2 = Request::builder()
        .method("POST")
        .uri("/v1/admin/deposits")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "event_id": "evt_it_1",
                "amount_micro_usd": 250_000,
                "withdrawable_micro_usd": 100_000
            })
            .to_string(),
        ))
        .unwrap();
    let res2 = app.oneshot(req2).await.unwrap();
    assert_eq!(res2.status(), StatusCode::OK);
    let v2 = body_json(res2).await;
    assert_eq!(v2["applied"], false);
    assert_eq!(v2["balance_micro_usd"], 1_250_000);
    // Replay must not enqueue a second outbox side effect.
    assert_eq!(outbox.lock().await.len(), 1);
}

#[tokio::test]
async fn chat_rejects_when_ownership_lost() {
    let app = router(test_state(false));
    let req = Request::builder()
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
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn quiescence_reports_ownership_and_empty_outbox() {
    let app = router(test_state(true));
    let req = Request::builder()
        .method("GET")
        .uri("/v1/admin/quiescence")
        .body(Body::empty())
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["ownership_holding"], true);
    assert_eq!(v["ownership_epoch"], 9);
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(v["outbox_retryable"], 0);
    assert_eq!(v["external_events_seen"], 0);
    assert_eq!(v["late_terminals"], 0);
}
