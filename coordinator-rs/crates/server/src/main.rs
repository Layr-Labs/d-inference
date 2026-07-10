use darkbloom_coordinator::cli::{parse_and_is_recovery, run_recovery};
use darkbloom_coordinator::{router, spawn_fleet_actor, AppState, MemoryLedger, ModelCard};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .json()
        .init();

    let (is_recovery, confirm) = parse_and_is_recovery();
    if is_recovery {
        if let Err(err) = run_recovery(confirm) {
            tracing::error!(%err, "recovery failed");
            std::process::exit(1);
        }
        return;
    }

    let (fleet, _fleet_join) = spawn_fleet_actor();
    let mut ledger = MemoryLedger::default();
    let pilot_account =
        std::env::var("DARKBLOOM_PILOT_ACCOUNT").unwrap_or_else(|_| "pilot-account".into());
    // Seed pilot balance ($100) so mock settle path can charge.
    ledger.credit(&pilot_account, 100_000_000, 0);
    let pilot_api_keys: Arc<Vec<String>> = Arc::new(
        std::env::var("DARKBLOOM_PILOT_API_KEYS")
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
    );
    let state = AppState {
        fleet,
        encryption_kid: std::env::var("DARKBLOOM_ENCRYPTION_KID").unwrap_or_else(|_| "dev".into()),
        models: vec![ModelCard {
            id: std::env::var("DARKBLOOM_PILOT_MODEL")
                .unwrap_or_else(|_| "pilot-text-model".into()),
            object: "model".into(),
            owned_by: "darkbloom".into(),
        }],
        ledger: Arc::new(Mutex::new(ledger)),
        pilot_account,
        pilot_api_keys,
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
