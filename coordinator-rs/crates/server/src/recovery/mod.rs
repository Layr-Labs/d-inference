//! Bounded durable-state recovery workers (plan §18.1).
//!
//! Every worker follows the same discipline:
//!
//! - Claims a BOUNDED batch from its dedicated partial index with
//!   `FOR UPDATE SKIP LOCKED`. The row lock is the worker lease: it expires
//!   with the claiming connection, so a dead worker never wedges a row.
//! - Repairs exclusively through the ledger reducers ([`crate::ledger`]) —
//!   recovery does not implement a second state machine (plan §7.2); every
//!   mutation is epoch-fenced and idempotent on a stable operation key.
//! - Runs on a jittered interval, emits depth/oldest-age metrics via
//!   tracing, and shuts down cleanly on its
//!   [`CancellationToken`](tokio_util::sync::CancellationToken).
//!
//! Workers (plan §18.1): reserved-never-dispatched, prepared-never-
//! authorized, start-authorized-with-unknown-delivery, terminals awaiting
//! settlement, the single-writer fee projection (plan §12.6), and the
//! outbox drain.

mod fees;
mod outbox;
mod sweeps;
mod worker;

use std::sync::Arc;
use std::time::Duration;

use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

use crate::ledger::Ledger;

pub use fees::project_fees;
pub use outbox::drain_outbox;
pub use sweeps::{
    settle_pending_terminals, sweep_prepared, sweep_reserved, sweep_start_authorized,
};
pub use worker::run_worker;

/// Policy windows and bounds for every recovery worker.
#[derive(Debug, Clone)]
pub struct RecoveryConfig {
    /// Tick interval; each worker adds its own jitter.
    pub interval: Duration,
    /// Maximum extra jitter per tick.
    pub jitter: Duration,
    /// Rows claimed per tick per worker.
    pub batch: i64,
    /// Extra grace after a reserved job's deadlines before it is released.
    pub reserved_grace: Duration,
    /// How long a preparing/prepared job may sit before its lease is
    /// considered expired and the reservation is released (plan §18.1).
    pub prepared_lease_ttl: Duration,
    /// Policy window after which a start-authorized job with unknown start
    /// delivery moves to review (plan §18.1; resending the start needs a
    /// live session, which the fleet consumes from the outbox).
    pub start_authorized_window: Duration,
    /// Outbox rows dead-letter after this many attempts.
    pub outbox_max_attempts: i32,
}

impl Default for RecoveryConfig {
    fn default() -> Self {
        Self {
            interval: Duration::from_secs(5),
            jitter: Duration::from_secs(2),
            batch: 64,
            reserved_grace: Duration::from_secs(30),
            prepared_lease_ttl: Duration::from_secs(60),
            start_authorized_window: Duration::from_secs(120),
            outbox_max_attempts: 8,
        }
    }
}

/// Spawns every recovery worker onto `tracker`. Each worker stops promptly
/// when `cancel` fires; join through the tracker (plan §15.1 step 3).
pub fn spawn_all(
    ledger: Arc<Ledger>,
    config: RecoveryConfig,
    cancel: CancellationToken,
    tracker: &TaskTracker,
) {
    macro_rules! spawn_sweep {
        ($name:literal, $f:path) => {{
            let ledger = Arc::clone(&ledger);
            let config = config.clone();
            let cancel = cancel.clone();
            tracker.spawn(async move {
                run_worker($name, &config, cancel, || {
                    let ledger = Arc::clone(&ledger);
                    let config = config.clone();
                    async move { $f(&ledger, &config).await }
                })
                .await;
            });
        }};
    }

    spawn_sweep!("recovery.reserved", sweeps::sweep_reserved);
    spawn_sweep!("recovery.prepared", sweeps::sweep_prepared);
    spawn_sweep!("recovery.start_authorized", sweeps::sweep_start_authorized);
    spawn_sweep!("recovery.terminals", sweeps::settle_pending_terminals);
    spawn_sweep!("recovery.fee_projection", fees::project_fees);
    spawn_sweep!("recovery.outbox", outbox::drain_outbox);
}
