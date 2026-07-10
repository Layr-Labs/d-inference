//! Darkbloom Rust coordinator binary (plan §15.1, §20, §26.1).
//!
//! Subcommands:
//!
//! - `serve` (default) — schema-gate, acquire single-active ownership,
//!   build the ledger/catalog/fleet, serve HTTP with graceful ordered
//!   shutdown, and release ownership as the FINAL mutating action.
//! - `migrate` — apply `coordinator-rs/migrations` and exit. Serving
//!   startup NEVER runs DDL (plan §20).
//!
//! Integration seams (this file stays thin):
//!
//! - [`wire_fleet`] calls `darkbloom_server::fleet::spawn(FleetConfig) ->
//!   FleetRuntime` against the frozen contracts conventions.
//! - [`wire_http`] calls `darkbloom_server::http::build_router_with`; the
//!   provider-connect handler and live provider-key directory stay
//!   defaulted until the session component is wired. The ops middleware
//!   keeps `/healthz` + `/readyz` authoritative here because readiness must
//!   include ownership health (plan §20), which the http module cannot see.

use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::{Method, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::{Json, Router};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use secrecy::ExposeSecret;
use serde_json::json;
use tokio::sync::watch;
use zeroize::Zeroize;

use darkbloom_core::fleet::admission::AdmissionConfig;
use darkbloom_protocol::crypto::nacl_box;

use darkbloom_server::catalog::Catalog;
use darkbloom_server::config::{Config, CoordinatorSecretSource};
use darkbloom_server::contracts::{
    fleet_channels, ApiKeyStore, AppState, CoordinatorKeys, FleetHandle, FleetReceivers,
    LedgerFacade,
};
use darkbloom_server::db;
use darkbloom_server::fleet;
use darkbloom_server::ledger::Ledger;
use darkbloom_server::ownership::OwnershipGuard;
use darkbloom_server::recovery::{self, RecoveryConfig};
use darkbloom_server::supervisor::Supervisor;

/// Per-phase drain bound during ordered shutdown.
const SHUTDOWN_PHASE_TIMEOUT: Duration = Duration::from_secs(10);

enum Command {
    Serve,
    Migrate,
}

fn parse_command() -> Result<Command, String> {
    match std::env::args().nth(1).as_deref() {
        None | Some("serve") => Ok(Command::Serve),
        Some("migrate") => Ok(Command::Migrate),
        Some(other) => Err(format!(
            "unknown subcommand '{other}' (expected: serve | migrate)"
        )),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let command = parse_command().map_err(anyhow::Error::msg)?;
    let config = Config::from_env().context("startup configuration")?;
    init_tracing(config.log_json);

    match command {
        Command::Migrate => cmd_migrate(&config).await,
        Command::Serve => cmd_serve(config).await,
    }
}

fn init_tracing(json: bool) {
    use tracing_subscriber::EnvFilter;
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    if json {
        tracing_subscriber::fmt()
            .with_env_filter(filter)
            .json()
            .init();
    } else {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    }
}

/// `coordinator-rs migrate`: the ONLY path that applies DDL (plan §20).
async fn cmd_migrate(config: &Config) -> anyhow::Result<()> {
    let pool = db::build_pool(config)
        .await
        .context("connect for migrate")?;
    db::run_migrations(&pool)
        .await
        .context("apply migrations")?;
    db::check_schema(&pool)
        .await
        .context("verify schema after migrate")?;
    tracing::info!("migrations applied; schema in supported range");
    Ok(())
}

async fn cmd_serve(config: Config) -> anyhow::Result<()> {
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
        encryption,
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

    let ops = OpsState {
        ownership_healthy: ownership.health_watch(),
        admission: supervisor.admission_watch(),
        fleet: fleet_handle,
    };
    // The ops layer answers /healthz and /readyz BEFORE routing so the
    // readiness gate (ownership + admission + fleet mailbox, plan §20) holds
    // even while the http module's own readyz is a placeholder.
    let router = wire_http(state, &supervisor)
        .unwrap_or_default()
        .layer(middleware::from_fn_with_state(ops, ops_endpoints));

    let listener = tokio::net::TcpListener::bind(config.listen_addr)
        .await
        .with_context(|| format!("bind {}", config.listen_addr))?;
    tracing::info!(addr = %config.listen_addr, epoch = ownership.epoch().get(), "serving");

    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal(ownership.health_watch()))
        .await
        .context("http server")?;

    // Ordered application shutdown (plan §15.1); the provider going-away
    // broadcast plugs into the middle slot at integration time.
    supervisor
        .shutdown(SHUTDOWN_PHASE_TIMEOUT, async {
            tracing::info!("going-away broadcast: no live provider sessions wired yet");
        })
        .await;

    // Release ownership as the FINAL mutating action (plan §26.1 step 7).
    if let Err(err) = ownership.release().await {
        tracing::warn!(error = %err, "ownership release failed; lock dies with the connection");
    }
    Ok(())
}

/// Spawns the fleet actor against the frozen seam
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

/// Consumer routes from the http adapter
/// (`http::build_router(AppState) -> axum::Router` per the contracts
/// conventions). The provider-connect handler and the live provider-key
/// directory stay defaulted until the session component is wired in the
/// integration phase.
fn wire_http(state: AppState, supervisor: &Supervisor) -> Option<Router> {
    Some(darkbloom_server::http::build_router_with(
        state,
        darkbloom_server::http::HttpConfig {
            shutdown: supervisor.requests().token(),
            ..Default::default()
        },
    ))
}

/// Readiness inputs (plan §20: readiness requires the lock-holding
/// connection to stay healthy; plan §14: the fleet mailbox must be alive).
#[derive(Clone)]
struct OpsState {
    ownership_healthy: watch::Receiver<bool>,
    admission: watch::Receiver<bool>,
    fleet: FleetHandle,
}

/// Intercepts the ops endpoints ahead of the router (see `cmd_serve`).
async fn ops_endpoints(
    State(ops): State<OpsState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    match (request.method(), request.uri().path()) {
        (&Method::GET, "/healthz") => "ok".into_response(),
        (&Method::GET, "/readyz") => readyz(&ops),
        _ => next.run(request).await,
    }
}

fn readyz(ops: &OpsState) -> Response {
    let ownership = *ops.ownership_healthy.borrow();
    let admission = *ops.admission.borrow();
    // The schema gate passed at startup or the process would not be serving.
    let fleet_mailbox = !ops.fleet.commands.is_closed();
    let ready = ownership && admission && fleet_mailbox;
    let status = if ready {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (
        status,
        Json(json!({
            "ready": ready,
            "ownership": ownership,
            "admission": admission,
            "fleet_mailbox": fleet_mailbox,
            "schema": true,
        })),
    )
        .into_response()
}

/// Coordinator X25519 identity from config: explicit secret, or a loud
/// ephemeral fallback for dev.
fn build_coordinator_keys(source: &CoordinatorSecretSource) -> anyhow::Result<CoordinatorKeys> {
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

/// Serve until Ctrl-C, SIGTERM, or ownership loss. Ownership loss MUST stop
/// admission and terminate the process after bounded drain (plan §20).
async fn shutdown_signal(mut ownership_health: watch::Receiver<bool>) {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut sig) => {
                sig.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };
    let ownership_lost = async {
        loop {
            if !*ownership_health.borrow_and_update() {
                return;
            }
            if ownership_health.changed().await.is_err() {
                return;
            }
        }
    };
    tokio::select! {
        () = ctrl_c => tracing::info!("shutdown: ctrl-c"),
        () = terminate => tracing::info!("shutdown: SIGTERM"),
        () = ownership_lost => tracing::error!(
            "shutdown: coordinator ownership LOST — stopping admission and draining (plan §20)"
        ),
    }
}
