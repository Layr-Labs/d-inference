//! HTTP: ownership heartbeat loss fences chat/deposits (DECISIONS #36).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::body_json;
use darkbloom_coordinator::{
    bounded_telemetry, router, run_ownership_heartbeat, spawn_fleet_actor, AppState,
    CoordinatorKeys, Epoch, ExternalEventInbox, LocalOwnershipStore, MemoryLedger,
    MemoryTerminalStore, ModelCard, Outbox, OwnershipGate, ProviderHub,
};
use darkbloom_core::PlacementController;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tower::ServiceExt;

fn holding_state(
    _store: Arc<LocalOwnershipStore>,
    gate: Arc<OwnershipGate>,
) -> AppState {
    let (fleet, _) = spawn_fleet_actor();
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
        coordinator_epoch: gate.epoch().0,
        ownership: gate,
        external_events: Arc::new(Mutex::new(ExternalEventInbox::new())),
        outbox: Arc::new(Mutex::new(Outbox::default())),
        terminals: Arc::new(Mutex::new(MemoryTerminalStore::new())),
        money_fx: Arc::new(Mutex::new(())),
        job_cancels: darkbloom_coordinator::JobCancelRegistry::new(),
    }
}

#[tokio::test]
async fn heartbeat_steal_fences_chat_and_deposits() {
    let store = Arc::new(LocalOwnershipStore::new(Duration::from_millis(40)));
    let gate = Arc::new(OwnershipGate::new(false));
    let epoch = store.acquire("coord-a").unwrap();
    gate.acquire(epoch).unwrap();

    let store_hb = store.clone();
    let gate_hb = gate.clone();
    tokio::spawn(async move {
        run_ownership_heartbeat(store_hb, gate_hb, "coord-a".into(), Duration::from_millis(10))
            .await;
    });

    let app = router(holding_state(store.clone(), gate.clone()));

    // Still holding — deposit ok.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_pre_steal",
                        "amount_micro_usd": 10_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    store.force_expire_for_test();
    let stolen = store.acquire("coord-b").unwrap();
    assert!(stolen > Epoch(0));
    assert_ne!(stolen, epoch);

    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(!gate.holding());

    let chat = app
        .clone()
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
    assert_eq!(chat.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(chat).await["error"]["code"], "ownership_lost");

    let dep = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_post_steal",
                        "amount_micro_usd": 10_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(dep.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(dep).await["error"]["code"], "ownership_lost");
}
