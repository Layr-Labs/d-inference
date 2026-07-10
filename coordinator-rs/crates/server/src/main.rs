use darkbloom_coordinator::{router, spawn_fleet_actor, AppState, ModelCard};
use std::net::SocketAddr;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .json()
        .init();

    let (fleet, _fleet_join) = spawn_fleet_actor();
    let state = AppState {
        fleet,
        encryption_kid: std::env::var("DARKBLOOM_ENCRYPTION_KID").unwrap_or_else(|_| "dev".into()),
        models: vec![ModelCard {
            id: std::env::var("DARKBLOOM_PILOT_MODEL")
                .unwrap_or_else(|_| "pilot-text-model".into()),
            object: "model".into(),
            owned_by: "darkbloom".into(),
        }],
    };

    let app = router(state);
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8080);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    tracing::info!(%addr, "darkbloom-coordinator warm plane listening");
    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("serve");
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutdown signal received");
}
