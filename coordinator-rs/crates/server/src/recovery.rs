//! Recovery workers — bounded claims over durable jobs (plan §18.1).
//!
//! Memory-backed for tests; Postgres SKIP LOCKED lands with SQLx.

use crate::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryAction {
    Released,
    AlreadyTerminal,
    Skipped,
}

/// Release reserved jobs that never reached start_authorized.
pub fn recover_undispatched(
    ledger: &Arc<Mutex<MemoryLedger>>,
    job_id: &str,
    account: &str,
) -> Result<RecoveryAction, String> {
    let mut g = ledger.lock().map_err(|e| e.to_string())?;
    if g.job_funded_start(job_id) {
        // start_authorized — must not auto-redispatch or auto-release in pilot.
        return Ok(RecoveryAction::Skipped);
    }
    if g.active_job_count() == 0 && g.job_reserved_total(job_id).is_none() {
        return Ok(RecoveryAction::AlreadyTerminal);
    }
    match g.release(
        OperationKey(format!("recovery_release:{job_id}")),
        job_id,
        account,
    ) {
        Ok(true) => Ok(RecoveryAction::Released),
        Ok(false) => Ok(RecoveryAction::AlreadyTerminal),
        Err(e) => Err(e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn releases_reserved_not_started() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0);
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
        }
        assert_eq!(
            recover_undispatched(&led, "j1", "a").unwrap(),
            RecoveryAction::Released
        );
        assert_eq!(led.lock().unwrap().balance("a").0, 1_000_000);
    }

    #[test]
    fn skips_start_authorized() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0);
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
            g.mark_start_authorized("j1").unwrap();
        }
        assert_eq!(
            recover_undispatched(&led, "j1", "a").unwrap(),
            RecoveryAction::Skipped
        );
    }
}
