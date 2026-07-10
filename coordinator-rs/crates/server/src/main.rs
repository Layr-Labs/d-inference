use darkbloom_coordinator::cli::{parse_and_is_recovery, run_recovery};
use darkbloom_coordinator::{
    bounded_telemetry, router, run_ownership_heartbeat, spawn_fleet_actor, AppState,
    CoordinatorKeys, ExternalEventInbox, LocalOwnershipStore, MemoryLedger, MemoryTerminalStore,
    ModelCard, Outbox, OwnershipGate, ProviderHub,
};
use darkbloom_core::PlacementController;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
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

    let refuse_on_rust = std::env::var("DARKBLOOM_REFUSE_ON_RUST")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let ownership = Arc::new(OwnershipGate::new(refuse_on_rust));
    // Process-local probe: MemoryLedger has no durable rust_coord rows.
    // When SQLx lands, probe rust_coord.* and call set_rust_active.
    ownership.set_rust_active(false);
    if let Err(err) = ownership.check_startup() {
        tracing::error!(%err, "refusing unsafe startup");
        std::process::exit(1);
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
    let holder = std::env::var("DARKBLOOM_OWNERSHIP_HOLDER")
        .unwrap_or_else(|_| format!("pid-{}", std::process::id()));
    let lease_ttl_secs: u64 = std::env::var("DARKBLOOM_OWNERSHIP_LEASE_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(30);
    let ownership_store = Arc::new(LocalOwnershipStore::new(Duration::from_secs(lease_ttl_secs)));
    let fencing_epoch = match ownership_store.acquire(&holder) {
        Ok(e) => e,
        Err(err) => {
            tracing::error!(%err, holder = %holder, "failed to acquire durable ownership");
            std::process::exit(1);
        }
    };
    if let Err(err) = ownership.acquire(fencing_epoch) {
        tracing::error!(%err, "failed to arm local ownership gate");
        std::process::exit(1);
    }
    let coordinator_epoch = fencing_epoch.0;
    {
        let store_hb = ownership_store.clone();
        let gate_hb = ownership.clone();
        let holder_hb = holder.clone();
        tokio::spawn(async move {
            run_ownership_heartbeat(
                store_hb,
                gate_hb,
                holder_hb,
                Duration::from_secs(lease_ttl_secs.max(1) / 3).max(Duration::from_millis(200)),
            )
            .await;
        });
    }
    let (telemetry, mut telemetry_worker) = bounded_telemetry(1024);
    tokio::spawn(async move {
        while telemetry_worker.drain_one().await.is_some() {
            // Best-effort drain; Datadog forwarder lands later.
        }
    });
    let ownership_for_shutdown = ownership.clone();
    let store_for_shutdown = ownership_store.clone();
    let holder_for_shutdown = holder.clone();
    let outbox_for_worker = Arc::new(Mutex::new(Outbox::default()));
    let outbox_for_state = outbox_for_worker.clone();
    tokio::spawn(async move {
        // Best-effort outbox drain (Datadog/projection forwarder lands with SQLx).
        // Critical money side effects stay in-flight until a durable forwarder acks
        // them (DECISIONS #32/#35) so quiescence cannot go ready after a silent drop.
        loop {
            let claimed = {
                let mut box_ = outbox_for_worker.lock().await;
                box_.try_claim()
            };
            match claimed {
                Some(entry) => {
                    let critical = entry.kind.starts_with("billing.")
                        || entry.kind.starts_with("inference.");
                    if critical {
                        tracing::debug!(
                            id = entry.id,
                            kind = %entry.kind,
                            "critical outbox held in-flight pending durable forwarder"
                        );
                    } else {
                        tracing::debug!(id = entry.id, kind = %entry.kind, "outbox delivered");
                        let mut box_ = outbox_for_worker.lock().await;
                        let _ = box_.ack_done(entry.id);
                    }
                }
                None => {
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
            }
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
        ownership,
        external_events: Arc::new(Mutex::new(ExternalEventInbox::new())),
        outbox: outbox_for_state,
        terminals: Arc::new(Mutex::new(MemoryTerminalStore::new())),
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
        .with_graceful_shutdown(shutdown_signal(
            ownership_for_shutdown,
            store_for_shutdown,
            holder_for_shutdown,
        ))
        .await
        .expect("serve");
}

async fn shutdown_signal(
    ownership: Arc<OwnershipGate>,
    store: Arc<LocalOwnershipStore>,
    holder: String,
) {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutdown signal received — releasing ownership");
    let epoch = ownership.epoch();
    let _ = store.release(&holder, epoch);
    ownership.release();
}
