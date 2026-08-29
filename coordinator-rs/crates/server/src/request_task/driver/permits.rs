//! Permit bookkeeping for fleet-minted dispatch permits (plan §9.2.10).
//! Invariant: every inserted permit is released exactly-once semantically —
//! `release_all` drains on ordinary exits and the `Drop` backstop covers a
//! dropped driver future; the release command itself is idempotent.

use std::collections::HashMap;

use tokio::sync::mpsc;

use darkbloom_core::ids::{AttemptId, PermitId, ProviderId};

use crate::contracts::FleetCommand;

/// Permit bookkeeping with a Drop backstop: releasing on drop is safe
/// because `FleetCommand::ReleasePermit` is idempotent (plan §9.2.10) and
/// `teardown()` drains the map first on every ordinary exit path, making
/// the Drop a no-op there.
pub(super) struct PermitLedger {
    fleet_commands: mpsc::Sender<FleetCommand>,
    permits: HashMap<AttemptId, (ProviderId, PermitId)>,
}

impl PermitLedger {
    pub(super) fn new(fleet_commands: mpsc::Sender<FleetCommand>) -> Self {
        Self {
            fleet_commands,
            permits: HashMap::new(),
        }
    }

    pub(super) fn insert(&mut self, attempt: AttemptId, provider: ProviderId, permit: PermitId) {
        self.permits.insert(attempt, (provider, permit));
    }

    pub(super) fn remove(&mut self, attempt: &AttemptId) -> Option<(ProviderId, PermitId)> {
        self.permits.remove(attempt)
    }

    pub(super) fn release_all(&mut self) {
        for (_, (provider, permit)) in self.permits.drain() {
            let _ = self
                .fleet_commands
                .try_send(FleetCommand::ReleasePermit { provider, permit });
        }
    }
}

impl Drop for PermitLedger {
    fn drop(&mut self) {
        self.release_all();
    }
}
