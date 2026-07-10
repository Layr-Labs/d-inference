//! Main-style application wiring (plan §15.1, §20, §25), shared verbatim by
//! the `coordinator-rs serve` binary and the full-stack integration tests so
//! the tested wiring IS the shipped wiring.
//!
//! [`build`] assembles: bounded pool + schema gate, single-active ownership,
//! catalog, ledger (also the API-key store and the provider-registration
//! beneficiary resolver), the fleet actor, the provider WebSocket handler,
//! and the axum router with the consolidated `/readyz` (ownership health AND
//! admission AND fleet-mailbox liveness — one implementation, in the http
//! module, fed by watch channels). [`App::serve`] runs the server with the
//! ordered shutdown: stop admission → drain request tasks → stop workers →
//! going-away → fence sessions → release ownership LAST.

use std::future::{Future, IntoFuture};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use axum::Router;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use secrecy::ExposeSecret;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;
use zeroize::Zeroize;

use darkbloom_core::fleet::admission::AdmissionConfig;
use darkbloom_protocol::crypto::nacl_box;

use crate::catalog::Catalog;
use crate::config::{Config, CoordinatorSecretSource};
use crate::contracts::{
    fleet_channels, ApiKeyStore, AppState, CoordinatorKeys, FleetHandle, FleetReceivers,
    LedgerFacade,
};
use crate::db;
use crate::fleet;
use crate::http;
use crate::ledger::Ledger;
use crate::ownership::OwnershipGuard;
use crate::provider_session::{self, SessionConfig, SessionDeps};
use crate::recovery::{self, RecoveryConfig};
use crate::supervisor::Supervisor;
use crate::trust::TrustVerifier;

/// Per-phase drain bound during ordered shutdown.
const SHUTDOWN_PHASE_TIMEOUT: Duration = Duration::from_secs(10);

/// The fully wired application, bound and ready to serve.
pub struct App {
    listener: tokio::net::TcpListener,
    router: Router,
    supervisor: Supervisor,
    ownership: OwnershipGuard,
    state: AppState,
    ledger: Arc<Ledger>,
}

/// Builds every component and binds the listener (plan §25 order: schema
/// gate, ownership, catalog/ledger, fleet, sessions, http).
pub async fn build(config: Config) -> anyhow::Result<App> {
    let pool = db::build_pool(&config)
        .await
        .context("build database pool")?;
    db::check_schema(&pool)
        .await
        .context("schema gate (plan §20)")?;

    // Single-active ownership BEFORE any mutator or worker starts
    // (plan §25 step 12).
    let ownership = OwnershipGuard::acquire(
        config.database_url.expose_secret(),
        &config.ownership_holder,
    )
    .await
    .context("acquire coordinator ownership")?;

    let catalog = Arc::new(Catalog::bootstrap(pool.clone(), config.catalog_file.clone()).await);
    let ledger = Arc::new(Ledger::new(
        pool.clone(),
        config.platform_account.clone(),
        ownership.epoch_cell(),
    ));
    let encryption = Arc::new(build_coordinator_keys(&config.coordinator_secret)?);

    let (fleet_handle, fleet_receivers) = fleet_channels(
        config.fleet_mailbox.commands,
        config.fleet_mailbox.heartbeats,
    );
    let admission_config = Arc::new(AdmissionConfig::default());
    let state = AppState {
        fleet: fleet_handle.clone(),
        ledger: Arc::clone(&ledger) as Arc<dyn LedgerFacade>,
        keys: Arc::clone(&ledger) as Arc<dyn ApiKeyStore>,
        catalog: catalog.snapshot_handle(),
        policy: Arc::new(config.policy.clone()),
        coordinator_epoch: ownership.epoch(),
        encryption: Arc::clone(&encryption),
        admission_config: Arc::clone(&admission_config),
    };

    let supervisor = Supervisor::new();

    // Background workers (stopped in phase 3 of the ordered shutdown).
    {
        let refresh = Arc::clone(&catalog);
        let token = supervisor.workers().token();
        supervisor.workers().spawn(async move {
            refresh.run_refresh(token).await;
        });
    }
    recovery::spawn_all(
        Arc::clone(&ledger),
        RecoveryConfig::default(),
        supervisor.workers().token(),
        supervisor.workers().tracker(),
    );

    wire_fleet(fleet_receivers, &state, &supervisor);

    // Provider WebSocket sessions: real SessionDeps over the same fleet,
    // coordinator identity, and ledger-backed auth-token resolver.
    let session_config = SessionConfig::default();
    let provider_max_frame_bytes = session_config.max_frame_bytes;
    let session_deps = SessionDeps {
        fleet: fleet_handle.clone(),
        trust: Arc::new(TrustVerifier::new()),
        keys: encryption,
        auth: Arc::clone(&ledger) as Arc<dyn ApiKeyStore>,
        coordinator_epoch: ownership.epoch(),
        config: session_config,
    };
    let provider_connect: http::ProviderConnectHandler = Arc::new(move |socket| {
        let deps = session_deps.clone();
        Box::pin(provider_session::serve(socket, deps))
    });

    let router = http::build_router_with(
        state.clone(),
        http::HttpConfig {
            provider_connect: Some(provider_connect),
            provider_max_frame_bytes,
            readiness: http::ReadinessInputs {
                ownership_healthy: ownership.health_watch(),
                admission_open: supervisor.admission_watch(),
            },
            shutdown: supervisor.requests().token(),
            ..Default::default()
        },
    );

    let listener = tokio::net::TcpListener::bind(config.listen_addr)
        .await
        .with_context(|| format!("bind {}", config.listen_addr))?;

    Ok(App {
        listener,
        router,
        supervisor,
        ownership,
        state,
        ledger,
    })
}

impl App {
    /// The bound address (ephemeral ports resolve here).
    pub fn local_addr(&self) -> anyhow::Result<SocketAddr> {
        self.listener.local_addr().context("listener local_addr")
    }

    /// Clonable fleet handle (stats/snapshot access for tests and ops).
    #[must_use]
    pub fn fleet_handle(&self) -> FleetHandle {
        self.state.fleet.clone()
    }

    /// The concrete ledger service (account directory access for tooling).
    #[must_use]
    pub fn ledger(&self) -> Arc<Ledger> {
        Arc::clone(&self.ledger)
    }

    #[must_use]
    pub fn coordinator_epoch(&self) -> darkbloom_core::ids::CoordinatorEpoch {
        self.state.coordinator_epoch
    }

    /// Serves until `shutdown` resolves or ownership is lost, then runs the
    /// ordered application shutdown (plan §15.1) and releases ownership as
    /// the FINAL mutating action (plan §26.1 step 7).
    ///
    /// The HTTP server task is stopped in parallel with the phased drain:
    /// axum's graceful shutdown alone would wait forever on upgraded
    /// provider WebSockets, which only close once the sessions phase fences
    /// them.
    pub async fn serve<F>(self, shutdown: F) -> anyhow::Result<()>
    where
        F: Future<Output = ()> + Send,
    {
        let App {
            listener,
            router,
            supervisor,
            ownership,
            state,
            ledger: _,
        } = self;

        let stop = CancellationToken::new();
        let server = axum::serve(listener, router).with_graceful_shutdown({
            let stop = stop.clone();
            async move { stop.cancelled().await }
        });
        let server_task = tokio::spawn(server.into_future());
        tracing::info!(epoch = state.coordinator_epoch.get(), "serving");

        tokio::select! {
            () = shutdown => tracing::info!("shutdown requested"),
            () = ownership_lost(ownership.health_watch()) => tracing::error!(
                "shutdown: coordinator ownership LOST — stopping admission and draining (plan §20)"
            ),
        }

        stop.cancel();
        supervisor
            .shutdown(SHUTDOWN_PHASE_TIMEOUT, async {
                // Session fencing rides the sessions-phase cancel: the fleet
                // actor stops and fences every live provider session.
                tracing::info!("going-away: fencing provider sessions via fleet shutdown");
            })
            .await;
        match tokio::time::timeout(SHUTDOWN_PHASE_TIMEOUT, server_task).await {
            Ok(joined) => {
                joined.context("http server task")?.context("http server")?;
            }
            Err(_) => tracing::warn!("http server did not drain in time; proceeding to release"),
        }

        // Release ownership as the FINAL mutating action (plan §26.1 step 7).
        if let Err(err) = ownership.release().await {
            tracing::warn!(error = %err, "ownership release failed; lock dies with the connection");
        }
        Ok(())
    }
}

/// Spawns the fleet actor against the contracts entry-point convention
/// (`fleet::spawn(FleetConfig) -> FleetRuntime`). The actor lives in the
/// sessions phase: it must outlive request tasks and workers, and stop when
/// provider sessions close.
fn wire_fleet(receivers: FleetReceivers, state: &AppState, supervisor: &Supervisor) {
    let cancel = supervisor.sessions().token();
    let runtime = fleet::spawn(fleet::FleetConfig {
        receivers,
        admission: *state.admission_config,
        catalog: Arc::clone(&state.catalog),
        cancel: cancel.clone(),
        tunables: fleet::FleetTunables::default(),
    });
    supervisor.sessions().spawn(async move {
        cancel.cancelled().await;
        runtime.shutdown().await;
    });
}

/// Coordinator X25519 identity from config: explicit secret, or a loud
/// ephemeral fallback for dev.
pub fn build_coordinator_keys(source: &CoordinatorSecretSource) -> anyhow::Result<CoordinatorKeys> {
    match source {
        CoordinatorSecretSource::EnvB64(b64) => {
            let mut bytes = BASE64
                .decode(b64.expose_secret())
                .context("DARKBLOOM_COORDINATOR_X25519_SECRET_B64 is not valid base64")?;
            let arr: [u8; 32] = bytes.as_slice().try_into().map_err(|_| {
                anyhow::anyhow!(
                    "DARKBLOOM_COORDINATOR_X25519_SECRET_B64 must decode to exactly 32 bytes, got {}",
                    bytes.len()
                )
            })?;
            let secret = nacl_box::SecretKey::from(arr);
            bytes.zeroize();
            Ok(CoordinatorKeys {
                x25519_public_b64: nacl_box::encode_public_key(&secret.public_key()),
                x25519_secret: secret,
            })
        }
        CoordinatorSecretSource::Ephemeral => {
            let (public, secret) = nacl_box::generate_keypair();
            tracing::warn!(
                "==============================================================\n\
                 DARKBLOOM_COORDINATOR_X25519_SECRET_B64 is NOT set.\n\
                 Generated an EPHEMERAL coordinator encryption key: providers\n\
                 will not recognize this coordinator across restarts and every\n\
                 sealed request will re-key. NEVER run production this way.\n\
                 =============================================================="
            );
            Ok(CoordinatorKeys {
                x25519_public_b64: nacl_box::encode_public_key(&public),
                x25519_secret: secret,
            })
        }
    }
}

/// Resolves when the ownership lock-holding connection reports unhealthy.
async fn ownership_lost(mut health: watch::Receiver<bool>) {
    loop {
        if !*health.borrow_and_update() {
            return;
        }
        if health.changed().await.is_err() {
            return;
        }
    }
}
