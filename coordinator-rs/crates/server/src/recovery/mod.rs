//! Bounded SKIP LOCKED recovery services.

mod external;
mod invariants;
mod jobs;
mod terminal;
mod worker;

use crate::{database::Database, db::ownership::DurableDatabase};

pub use external::{ExternalDisposition, ExternalEventLease, OutboxDisposition, OutboxLease};
pub use invariants::{InvariantReport, InvariantViolation};
pub use jobs::{
    AuthorizedAttemptRecovery, JobRecoveryAction, JobRecoveryLease, TerminalRecoveryLease,
};
pub use terminal::RecoveredTerminalDisposition;
pub use worker::{RecoveryRuntime, RecoveryRuntimeConfig, RecoveryRuntimeError};

/// Concrete recovery claimant for durable jobs, terminals, external events,
/// and outbox work.
#[derive(Clone, Debug)]
pub struct RecoveryService {
    pub(crate) db: DurableDatabase,
}

impl RecoveryService {
    #[must_use]
    pub fn new(database: Database) -> Self {
        Self {
            db: DurableDatabase::new(database),
        }
    }
}
