//! HTTP: quiescence held after resize_and_authorize; force_settle clears.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use darkbloom_coordinator::{
    bounded_telemetry, router, spawn_fleet_actor, AppState, CoordinatorKeys, Epoch,
    ExternalEventInbox, MemoryLedger, MemoryTerminalStore, ModelCard, OperationKey, Outbox,
    OwnershipGate, ProviderHub,
};
use darkbloom_core::PlacementController;
use http_body_util::BodyExt;
use std::sync::Arc;
use tokio::sync::Mutex;
use tower::ServiceExt;

fn test_state() -> AppState {
    let (fleet, _) = spawn_fleet_actor();
    let ownership = Arc::new(OwnershipGate::new(false));
    ownership.acquire(Epoch(3)).unwrap();
    let (telemetry, _worker) = bounded_telemetry(16);
    let mut ledger = MemoryLedger::default();
    ledger.credit("pilot-account", 10_000_000, 0).unwrap();
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
        coordinator_epoch: 3,
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
async fn quiescence_held_after_resize_then_cleared_by_force_settle() {
    let state = test_state();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(OperationKey("r".into()), "held-ra", "pilot-account", 100_000)
            .unwrap();
        led.resize_and_authorize(OperationKey("ra".into()), "held-ra", "pilot-account", 250_000)
            .unwrap();
    }
    let app = router(state.clone());
    let q1 = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q1.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v1 = body_json(q1).await;
    assert_eq!(v1["held_start_authorized"], 1);
    assert_eq!(v1["held_start_authorized_job_ids"][0], "held-ra");

    {
        let mut led = state.ledger.lock().await;
        assert!(led
            .settle_capped_as(
                OperationKey("force_settle:held-ra".into()),
                "held-ra",
                "pilot-account",
                80_000,
                250_000,
                "force-ra-d",
                "force_settled",
            )
            .unwrap());
    }

    let q2 = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q2.status(), StatusCode::OK);
    let v2 = body_json(q2).await;
    assert_eq!(v2["ready"], true);
    assert_eq!(v2["held_start_authorized"], 0);
    assert_eq!(v2["active_jobs"], 0);
}
