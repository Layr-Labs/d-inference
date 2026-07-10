use darkbloom_coordinator::cli::{parse_and_is_recovery, run_recovery};
use darkbloom_coordinator::{
    bounded_telemetry, router, spawn_fleet_actor, AppState, CoordinatorKeys, MemoryLedger,
    ModelCard, ProviderHub,
};
use darkbloom_core::PlacementController;
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

    let opts = parse_and_is_recovery();
    if opts.enabled {
        if let Err(err) = run_recovery(opts) {
            tracing::error!(%err, "recovery failed");
            std::process::exit(1);
        }
        return;
    }

    let (fleet, _fleet_join) = spawn_fleet_actor();
    let hub = ProviderHub::new();
    let kid = std::env::var("DARKBLOOM_ENCRYPTION_KID").unwrap_or_else(|_| "dev".into());
    let keys = if let Ok(seed_b64) = std::env::var("DARKBLOOM_COORDINATOR_SEED_B64") {
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(seed_b64.trim())
            .expect("DARKBLOOM_COORDINATOR_SEED_B64 must be 32-byte base64");
        let mut seed = [0u8; 32];
        assert_eq!(bytes.len(), 32, "seed must be 32 bytes");
        seed.copy_from_slice(&bytes);
        CoordinatorKeys::from_seed(seed, kid)
    } else {
        CoordinatorKeys::generate(kid)
    };
    let mut ledger = MemoryLedger::default();
    let pilot_account =
        std::env::var("DARKBLOOM_PILOT_ACCOUNT").unwrap_or_else(|_| "pilot-account".into());
    ledger.credit(&pilot_account, 100_000_000, 0).unwrap();
    let pilot_api_keys: Arc<Vec<String>> = Arc::new(
        std::env::var("DARKBLOOM_PILOT_API_KEYS")
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
    );
    let coordinator_epoch: u64 = std::env::var("DARKBLOOM_COORDINATOR_EPOCH")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1);
    let (telemetry, mut telemetry_worker) = bounded_telemetry(1024);
    tokio::spawn(async move {
        while telemetry_worker.drain_one().await.is_some() {
            // Best-effort drain; Datadog forwarder lands later.
        }
    });
    let state = AppState {
        fleet,
        hub,
        keys,
        models: vec![ModelCard {
            id: std::env::var("DARKBLOOM_PILOT_MODEL")
                .unwrap_or_else(|_| "pilot-text-model".into()),
            object: "model".into(),
            owned_by: "darkbloom".into(),
        }],
        ledger: Arc::new(Mutex::new(ledger)),
        placement: Arc::new(Mutex::new(PlacementController::default())),
        telemetry: Arc::new(telemetry),
        pilot_account,
        pilot_api_keys,
        coordinator_epoch,
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
