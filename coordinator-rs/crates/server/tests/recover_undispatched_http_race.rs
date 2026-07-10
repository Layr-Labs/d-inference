//! Concurrent HTTP recover-undispatched: exactly one released.

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
use tokio::sync::Mutex;
use tower::ServiceExt;

fn test_state() -> AppState {
    let (fleet, _) = spawn_fleet_actor();
    let ownership = std::sync::Arc::new(OwnershipGate::new(false));
    ownership.acquire(Epoch(9)).unwrap();
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
        ledger: std::sync::Arc::new(Mutex::new(ledger)),
        placement: std::sync::Arc::new(Mutex::new(PlacementController::default())),
        telemetry: std::sync::Arc::new(telemetry),
        pilot_account: "pilot-account".into(),
        pilot_api_keys: std::sync::Arc::new(vec![]),
        coordinator_epoch: 9,
        ownership,
        external_events: std::sync::Arc::new(Mutex::new(ExternalEventInbox::new())),
        outbox: std::sync::Arc::new(Mutex::new(Outbox::default())),
        terminals: std::sync::Arc::new(Mutex::new(MemoryTerminalStore::new())),
    }
}

async fn body_json(res: axum::response::Response) -> serde_json::Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn concurrent_http_recover_undispatched_exactly_one_released() {
    let state = test_state();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-cru".into()),
            "undisp-cru",
            "pilot-account",
            120_000,
        )
        .unwrap();
    }
    let app = router(state);
    let mut handles = Vec::new();
    for _ in 0..8 {
        let app = app.clone();
        handles.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/recover-undispatched")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({ "job_id": "undisp-cru" }).to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["action"].as_str().unwrap().to_string()
        }));
    }

    let mut released = 0usize;
    let mut terminal = 0usize;
    for h in handles {
        match h.await.unwrap().as_str() {
            "released" => released += 1,
            "already_terminal" => terminal += 1,
            other => panic!("unexpected action {other}"),
        }
    }
    assert_eq!(released, 1);
    assert_eq!(terminal, 7);
}
