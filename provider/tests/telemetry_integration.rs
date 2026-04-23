//! End-to-end test: spawn a local HTTP server mocking the coordinator's
//! `/v1/telemetry/events` endpoint and assert that the provider's telemetry
//! client batches events and delivers them.
//!
//! Because the `darkbloom` crate is a binary-only crate, we reimplement a
//! thin client here that exercises the same reqwest+serde wire path. If this
//! flow changes in `src/telemetry/client.rs` the test should be kept in
//! sync — the symmetry test in `telemetry_symmetry.rs` already guards the
//! JSON shape.

use axum::{Json, Router, routing::post};
use serde::{Deserialize, Serialize};
use std::net::TcpListener;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

#[derive(Debug, Deserialize, Serialize)]
struct Batch {
    events: Vec<serde_json::Value>,
}

#[tokio::test]
async fn telemetry_client_posts_batch_to_coordinator() {
    // Find a free port for the mock server.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);

    let received = Arc::new(AtomicUsize::new(0));
    let counter = received.clone();

    // Spawn a minimal coordinator stub.
    let app = Router::new().route(
        "/v1/telemetry/events",
        post(move |Json(batch): Json<Batch>| {
            let c = counter.clone();
            async move {
                c.fetch_add(batch.events.len(), Ordering::SeqCst);
                Json(serde_json::json!({"accepted": batch.events.len(), "rejected": 0}))
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    let server_handle = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    // Small delay to ensure the listener is accepting.
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    // Build + POST a batch identical in shape to what the provider sends.
    let url = format!("http://{}/v1/telemetry/events", addr);
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "events": [
            {
                "id": "00000000-0000-0000-0000-000000000001",
                "timestamp": "2026-04-16T00:00:00.000000000Z",
                "source": "provider",
                "severity": "error",
                "kind": "backend_crash",
                "message": "test",
                "session_id": "s1",
                "version": "0.3.10",
                "fields": {"backend": "vllm-mlx", "exit_code": 1}
            }
        ]
    });
    let resp = client.post(&url).json(&body).send().await.unwrap();
    assert!(resp.status().is_success());

    assert_eq!(received.load(Ordering::SeqCst), 1);
    server_handle.abort();
}
