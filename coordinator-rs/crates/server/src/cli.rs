//! Recovery subcommand — same-release emergency tool (plan §26.2).
//!
//! Accepts no new consumer traffic. Reacquires settlement authority only.
//! Live Postgres wiring requires DATABASE_URL; this binary path documents
//! the operator interface and refuses unsafe modes without it.

use clap::{Parser, Subcommand};

#[derive(Parser, Debug)]
#[command(name = "darkbloom-coordinator", about = "Darkbloom Rust coordinator")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Serve the warm-plane HTTP/WS API (default when no subcommand).
    Serve,
    /// Recovery-only mode: settle/release rust_coord jobs; no admission.
    Recovery {
        /// Require explicit confirmation that this is the same-release artifact.
        #[arg(long)]
        confirm_same_release: bool,
    },
}

pub fn parse_and_is_recovery() -> (bool, bool) {
    let cli = Cli::parse();
    match cli.command {
        None | Some(Commands::Serve) => (false, false),
        Some(Commands::Recovery {
            confirm_same_release,
        }) => (true, confirm_same_release),
    }
}

pub fn run_recovery(confirm: bool) -> Result<(), String> {
    if !confirm {
        return Err(
            "recovery requires --confirm-same-release (plan §26.2: same-release artifact only)"
                .into(),
        );
    }
    let url = std::env::var("DATABASE_URL").map_err(|_| {
        "DATABASE_URL required for recovery mode".to_string()
    })?;
    tracing::info!(%url, "recovery mode: would probe rust_coord and settle/release (SQLx not linked in this build)");
    Err(
        "recovery SQL execution not linked in this agent build — apply migrations and use sqlx-enabled image"
            .into(),
    )
}
