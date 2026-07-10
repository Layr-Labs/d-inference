//! Shared Axum test helpers for coordinator-rs server integration tests.

use axum::body::Body;
use darkbloom_coordinator::{
    bounded_telemetry, spawn_fleet_actor, AppState, CoordinatorKeys, Epoch, ExternalEventInbox,
    MemoryLedger, MemoryTerminalStore, ModelCard, Outbox, OwnershipGate, ProviderHub,
};
use darkbloom_core::PlacementController;
use http_body_util::BodyExt;
use std::sync::Arc;
use tokio::sync::Mutex;

/// Build a pilot AppState. When `holding` is true, ownership epoch 9 is acquired.
#[allow(dead_code)] // not every HTTP test binary uses this helper
pub fn pilot_app_state(holding: bool) -> AppState {
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
        money_fx: Arc::new(Mutex::new(())),
        job_cancels: darkbloom_coordinator::JobCancelRegistry::new(),
    }
}

#[allow(dead_code)] // not every HTTP test binary uses this helper
pub async fn body_json(res: axum::response::Response) -> serde_json::Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

#[allow(dead_code)]
pub fn json_body(v: &serde_json::Value) -> Body {
    Body::from(v.to_string())
}
