//! HTTP: claim without ack keeps quiescence not-ready (DECISIONS #35).

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

fn test_state() -> AppState {
    let (fleet, _) = spawn_fleet_actor();
    let ownership = Arc::new(OwnershipGate::new(false));
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
async fn claim_without_ack_keeps_quiescence_blocked() {
    let state = test_state();
    let outbox = state.outbox.clone();
    let app = router(state);
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_inflight_q",
                        "amount_micro_usd": 25_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let entry = {
        let mut box_ = outbox.lock().await;
        box_.try_claim().unwrap()
    };
    assert_eq!(outbox.lock().await.in_flight_len(), 1);

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
    assert_eq!(body_json(q1).await["outbox_retryable"], 1);

    {
        let mut box_ = outbox.lock().await;
        box_.ack_done(entry.id).unwrap();
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
    assert_eq!(body_json(q2).await["outbox_retryable"], 0);
}
