//! Recovery subcommand — same-release emergency tool (plan §26.2).

use clap::{Parser, Subcommand};
use std::sync::{Arc, Mutex};

use crate::deposits::apply_stripe_deposit;
use crate::external_events::ExternalEventInbox;
use crate::ledger::MemoryLedger;
use crate::recovery::{
    force_settle_held, recover_start_authorized_held, recover_undispatched, RecoveryAction,
};

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
        /// In-memory demo: release a reserved (not start-authorized) job.
        #[arg(long)]
        demo_job: Option<String>,
        /// In-memory demo: classify a start_authorized held job (no money move).
        #[arg(long)]
        demo_held_job: Option<String>,
        /// In-memory demo: force-settle a start_authorized held job.
        #[arg(long)]
        demo_force_settle_job: Option<String>,
        /// In-memory demo: apply a Stripe deposit event (idempotent).
        #[arg(long)]
        demo_deposit_event: Option<String>,
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
            demo_held_job: None,
            demo_force_settle_job: None,
            demo_deposit_event: None,
            demo_account: String::new(),
        },
        Some(Commands::Recovery {
            confirm_same_release,
            demo_job,
            demo_held_job,
            demo_force_settle_job,
            demo_deposit_event,
            demo_account,
        }) => RecoveryOpts {
            enabled: true,
            confirm: confirm_same_release,
            demo_job,
            demo_held_job,
            demo_force_settle_job,
            demo_deposit_event,
            demo_account,
        },
    }
}

pub struct RecoveryOpts {
    pub enabled: bool,
    pub confirm: bool,
    pub demo_job: Option<String>,
    pub demo_held_job: Option<String>,
    pub demo_force_settle_job: Option<String>,
    pub demo_deposit_event: Option<String>,
    pub demo_account: String,
}

pub fn run_recovery(opts: RecoveryOpts) -> Result<(), String> {
    if !opts.confirm {
        return Err(
            "recovery requires --confirm-same-release (plan §26.2: same-release artifact only)"
                .into(),
        );
    }
    if let Some(event_id) = opts.demo_deposit_event {
        let mut inbox = ExternalEventInbox::new();
        let mut led = MemoryLedger::default();
        let applied = apply_stripe_deposit(
            &mut inbox,
            &mut led,
            "stripe",
            &event_id,
            &opts.demo_account,
            250_000,
            50_000,
        )
        .map_err(|e| e.to_string())?;
        if !applied {
            return Err("expected first deposit apply".into());
        }
        let replay = apply_stripe_deposit(
            &mut inbox,
            &mut led,
            "stripe",
            &event_id,
            &opts.demo_account,
            250_000,
            50_000,
        )
        .map_err(|e| e.to_string())?;
        if replay {
            return Err("expected replay to be a no-op".into());
        }
        let (bal, wdr) = led.balance(&opts.demo_account);
        if bal != 250_000 || wdr != 50_000 {
            return Err(format!("expected bal=250000 wdr=50000, got {bal}/{wdr}"));
        }
        tracing::info!(%event_id, bal, wdr, "recovery deposit demo complete");
        return Ok(());
    }
    if let Some(job) = opts.demo_force_settle_job {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().map_err(|e| e.to_string())?;
            g.credit(&opts.demo_account, 1_000_000, 0).unwrap();
            g.reserve(
                crate::ledger::OperationKey(format!("reserve:{job}")),
                &job,
                &opts.demo_account,
                100_000,
            )
            .map_err(|e| e.to_string())?;
            g.mark_start_authorized(&job, &opts.demo_account)
                .map_err(|e| e.to_string())?;
        }
        let action = force_settle_held(&led, &job, &opts.demo_account, 40_000, "force-demo-d")?;
        tracing::info!(?action, job, "recovery force-settle demo complete");
        if action != RecoveryAction::Released {
            return Err(format!("expected Released (settled), got {action:?}"));
        }
        let bal = led.lock().map_err(|e| e.to_string())?.balance(&opts.demo_account).0;
        // reserved 100k, charged 40k → refund 60k → 960k
        if bal != 960_000 {
            return Err(format!("expected balance 960000 after force settle, got {bal}"));
        }
        return Ok(());
    }
    if let Some(job) = opts.demo_held_job {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().map_err(|e| e.to_string())?;
            g.credit(&opts.demo_account, 1_000_000, 0).unwrap();
            g.reserve(
                crate::ledger::OperationKey(format!("reserve:{job}")),
                &job,
                &opts.demo_account,
                100_000,
            )
            .map_err(|e| e.to_string())?;
            g.mark_start_authorized(&job, &opts.demo_account)
                .map_err(|e| e.to_string())?;
        }
        let action = recover_start_authorized_held(&led, &job)?;
        tracing::info!(?action, job, "recovery held-job demo complete");
        if action != RecoveryAction::HeldForReview {
            return Err(format!("expected HeldForReview, got {action:?}"));
        }
        // Money still held.
        let bal = led.lock().map_err(|e| e.to_string())?.balance(&opts.demo_account).0;
        if bal != 900_000 {
            return Err(format!("expected held balance 900000, got {bal}"));
        }
        return Ok(());
    }
    if let Some(job) = opts.demo_job {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().map_err(|e| e.to_string())?;
            g.credit(&opts.demo_account, 1_000_000, 0).unwrap();
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
        "DATABASE_URL required for recovery mode (or pass --demo-job / --demo-held-job / --demo-force-settle-job / --demo-deposit-event for in-memory dry-run)"
            .to_string()
    })?;
    tracing::info!(%url, "recovery mode: would probe rust_coord and settle/release (SQLx not linked in this build)");
    Err(
        "recovery SQL execution not linked in this agent build — apply migrations and use sqlx-enabled image"
            .into(),
    )
}
