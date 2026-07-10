use axum::{routing::get, Json, Router};
use serde_json::{json, Value};
use std::net::SocketAddr;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .json()
        .init();

    let app = Router::new()
        .route("/health", get(health))
        .route("/readyz", get(readyz));

    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    tracing::info!(%addr, "darkbloom-coordinator listening (warm-plane stub)");
    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    axum::serve(listener, app).await.expect("serve");
}

async fn health() -> Json<Value> {
    Json(json!({ "status": "ok", "coordinator": "rust", "phase": "m1-scaffold" }))
}

async fn readyz() -> Json<Value> {
    // Milestone 3 will require FleetActor + DB ownership + settlement workers.
    Json(json!({ "ready": false, "reason": "scaffold_only" }))
}
