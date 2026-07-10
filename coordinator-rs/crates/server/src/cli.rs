//! Recovery subcommand — same-release emergency tool (plan §26.2).

use clap::{Parser, Subcommand};
use std::sync::{Arc, Mutex};

use crate::ledger::MemoryLedger;
use crate::recovery::{recover_undispatched, RecoveryAction};

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
    /// Recovery-only mode: settle/release jobs; no admission.
    Recovery {
        /// Require explicit confirmation that this is the same-release artifact.
        #[arg(long)]
        confirm_same_release: bool,
        /// Optional in-memory demo: release a reserved job (tests / dry-run).
        #[arg(long)]
        demo_job: Option<String>,
        #[arg(long, default_value = "pilot-account")]
        demo_account: String,
    },
}

pub fn parse_and_is_recovery() -> RecoveryOpts {
    let cli = Cli::parse();
    match cli.command {
        None | Some(Commands::Serve) => RecoveryOpts {
            enabled: false,
            confirm: false,
            demo_job: None,
            demo_account: String::new(),
        },
        Some(Commands::Recovery {
            confirm_same_release,
            demo_job,
            demo_account,
        }) => RecoveryOpts {
            enabled: true,
            confirm: confirm_same_release,
            demo_job,
            demo_account,
        },
    }
}

pub struct RecoveryOpts {
    pub enabled: bool,
    pub confirm: bool,
    pub demo_job: Option<String>,
    pub demo_account: String,
}

pub fn run_recovery(opts: RecoveryOpts) -> Result<(), String> {
    if !opts.confirm {
        return Err(
            "recovery requires --confirm-same-release (plan §26.2: same-release artifact only)"
                .into(),
        );
    }
    if let Some(job) = opts.demo_job {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().map_err(|e| e.to_string())?;
            g.credit(&opts.demo_account, 1_000_000, 0);
            g.reserve(
                crate::ledger::OperationKey(format!("reserve:{job}")),
                &job,
                &opts.demo_account,
                100_000,
            )
            .map_err(|e| e.to_string())?;
        }
        let action = recover_undispatched(&led, &job, &opts.demo_account)?;
        tracing::info!(?action, job, "recovery demo complete");
        if action != RecoveryAction::Released {
            return Err(format!("expected Released, got {action:?}"));
        }
        return Ok(());
    }
    let url = std::env::var("DATABASE_URL").map_err(|_| {
        "DATABASE_URL required for recovery mode (or pass --demo-job for in-memory dry-run)"
            .to_string()
    })?;
    tracing::info!(%url, "recovery mode: would probe rust_coord and settle/release (SQLx not linked in this build)");
    Err(
        "recovery SQL execution not linked in this agent build — apply migrations and use sqlx-enabled image"
            .into(),
    )
}
