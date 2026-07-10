//! Darkbloom Rust coordinator binary (plan §15.1, §20, §26.1).
//!
//! Subcommands:
//!
//! - `serve` (default) — build the full application via
//!   [`darkbloom_server::bootstrap`] (schema gate, single-active ownership,
//!   catalog/ledger/fleet/sessions/http) and serve with graceful ordered
//!   shutdown. Readiness lives in the http module's `/readyz`, fed by the
//!   ownership and admission watch channels.
//! - `migrate` — apply `coordinator-rs/migrations` and exit. Serving
//!   startup NEVER runs DDL (plan §20).
//!
//! This file stays thin: everything the tests must exercise identically is
//! in `bootstrap::build` / `bootstrap::App::serve`.

use anyhow::Context;

use darkbloom_server::bootstrap;
use darkbloom_server::config::Config;
use darkbloom_server::db;

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
        Command::Serve => {
            let app = bootstrap::build(config).await?;
            app.serve(shutdown_signal()).await
        }
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

/// Resolves on Ctrl-C or SIGTERM. Ownership loss is watched inside
/// `App::serve` (plan §20: loss must stop admission and drain).
async fn shutdown_signal() {
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
    tokio::select! {
        () = ctrl_c => tracing::info!("shutdown: ctrl-c"),
        () = terminate => tracing::info!("shutdown: SIGTERM"),
    }
}
