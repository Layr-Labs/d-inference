//! Bounded SKIP LOCKED recovery services.

mod external;
mod jobs;

use crate::{database::Database, db::ownership::DurableDatabase};

pub use external::{ExternalDisposition, ExternalEventLease, OutboxDisposition, OutboxLease};
pub use jobs::{JobRecoveryAction, JobRecoveryLease, TerminalRecoveryLease};

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
