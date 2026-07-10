//! Concurrent outbox enqueue while deposit applies: quiescence not ready until drain.

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
    ownership.acquire(Epoch(1)).unwrap();
    let (telemetry, _worker) = bounded_telemetry(16);
    AppState {
        fleet,
        hub: ProviderHub::new(),
        keys: CoordinatorKeys::generate("test"),
        models: vec![ModelCard {
            id: "pilot-text-model".into(),
            object: "model".into(),
            owned_by: "darkbloom".into(),
        }],
        ledger: Arc::new(Mutex::new(MemoryLedger::default())),
        placement: Arc::new(Mutex::new(PlacementController::default())),
        telemetry: Arc::new(telemetry),
        pilot_account: "pilot-account".into(),
        pilot_api_keys: Arc::new(vec![]),
        coordinator_epoch: 1,
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
async fn two_deposits_two_outbox_entries_block_quiescence_until_both_drained() {
    let state = test_state();
    let outbox = state.outbox.clone();
    let app = router(state);

    for (i, amt) in [(1, 10_000), (2, 20_000)] {
        let res = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/deposits")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "event_id": format!("evt_multi_{i}"),
                            "amount_micro_usd": amt,
                            "withdrawable_micro_usd": 0
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
    }
    assert_eq!(outbox.lock().await.len(), 2);

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
    assert_eq!(v1["ready"], false);
    assert_eq!(v1["outbox_retryable"], 2);

    // Drain one
    {
        let mut box_ = outbox.lock().await;
        let e = box_.try_claim().unwrap();
        box_.ack_done(e.id);
    }
    let q2 = app
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
    assert_eq!(q2.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(q2).await["outbox_retryable"], 1);

    // Drain second
    {
        let mut box_ = outbox.lock().await;
        let e = box_.try_claim().unwrap();
        box_.ack_done(e.id);
    }
    let q3 = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q3.status(), StatusCode::OK);
    let v3 = body_json(q3).await;
    assert_eq!(v3["ready"], true);
    assert_eq!(v3["outbox_retryable"], 0);
}
